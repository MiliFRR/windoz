import Foundation

/// The engine boundary. **Nothing above this file may import Wine, FEX or DXMT
/// symbols.** The UI talks to `WindozEngine` and to plain value types only.
///
/// What is underneath: the pinned engine forks (Wine ARM64EC, FEX-Emu, DXMT and
/// the native D3D12 runtime) driven by the C/ObjC binding layer that those forks
/// require. See `docs/ENGINE.md` for the exact boundary and what each entry
/// point maps to.
///
/// Honesty contract: every method either does the thing it says, or throws an
/// `EngineError` that names the exact missing piece. Nothing here pretends to
/// run a game when the session host has not been ported yet.
final class WindozEngine: ObservableObject {
    static let shared = WindozEngine()

    @Published private(set) var status = EngineStatus()
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var currentGameID: UUID?

    let log = EngineLogStream.shared
    private(set) var prefix: PrefixManager

    private let queue = DispatchQueue(label: "windoz.engine", qos: .userInitiated)
    /// Status probes run on their own queue: they must never wait behind a
    /// long engine-core test (device bug 2026-10-17: the JIT/memory rows sat
    /// at "Checking…" while the core test held `queue`).
    private let probes = DispatchQueue(label: "windoz.probes", qos: .userInitiated)
    private var sessionStart: Date?
    private var callbacksInstalled = false

    init(prefix: PrefixManager = PrefixManager(base: AppContainer.documents)) {
        self.prefix = prefix
        installCallbacks()
    }

    private func installCallbacks() {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true
        fex_set_log_callback(windozEngineLogTrampoline)
        jit_set_log_callback(windozEngineLogTrampoline)
    }

    // MARK: - Health

    /// Probe JIT, the memory entitlement, free storage and signing expiry.
    /// Safe to call often; the work is off the main thread.
    func refreshStatus() {
        status.jit = .checking
        status.memoryEntitlement = .checking
        status.runningInLiveContainer = AppEnvironment.isLiveContainer
        probes.async { [weak self] in
            guard let self else { return }
            let jitOK = JITManager.probeEnabled()
            let memory = JITManager.memoryEntitlementHealth
            let free = Self.freeStorageBytes()
            let expiry = JITManager.signingExpiryDate()
            let footprint = JITManager.physicalFootprintBytes()
            DispatchQueue.main.async {
                self.status.jit = jitOK ? .ready : .unavailable(Self.jitExplanation())
                self.status.memoryEntitlement = memory
                self.status.freeStorageBytes = free
                self.status.signingExpiresAt = expiry
                self.status.memoryFootprintBytes = footprint
            }
        }
    }

    private static func jitExplanation() -> String {
        if AppEnvironment.isSimulator {
            return "JIT is not available in the Simulator."
        }
        if JITManager.flaggedWithoutDebugger {
            return "JIT was enabled, but the debugger is no longer attached — the engine's JIT requests need one to answer them. Enable JIT again and keep StikDebug attached."
        }
        if AppEnvironment.isLiveContainer {
            return "JIT is off. Inside LiveContainer, turn on “Launch with JIT”, point its script at Documents/LiveContainer/windoz-jit.js, then attach StikDebug (Windoz's bundled helper cannot be used here)."
        }
        return "JIT is off. Enable it from Setup with StikDebug, or with Windoz's bundled helper on a normal sideload."
    }

    static func freeStorageBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return bytes
    }

    // MARK: - Session state

    var isSessionActive: Bool { phase.isActive }

    // MARK: - Prefix

    var prefixIsReady: Bool { prefix.exists }

    func createPrefix() throws {
        try prefix.createIfNeeded()
        log.append("Windows environment ready at \(prefix.url.path)", level: .success)
    }

    func repairPrefix() throws {
        guard !phase.isActive else { throw EngineError.sessionAlreadyRunning }
        try prefix.repair()
        log.append("Windows environment repaired (clean template extracted).", level: .success)
    }

    func deletePrefix() throws {
        guard !phase.isActive else { throw EngineError.sessionAlreadyRunning }
        try prefix.delete()
        log.append("Windows environment deleted.", level: .warning)
    }

    // MARK: - Engine core

    /// Start the engine's core services (the Wine service process and the FEX
    /// translator) without a game. This is the part that is fully wired and is
    /// what the diagnostics screen exercises on device.
    func startEngineCore() async throws {
        try prefix.createIfNeeded()

        let ready = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                let rc = wineserver_start(self.prefix.url.path)
                guard rc == 0 else { continuation.resume(throwing: EngineError.wineserverStartFailed); return }
                for _ in 0..<120 {                       // up to ~60 s
                    if wineserver_is_ready() == 1 { continuation.resume(returning: true); return }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                continuation.resume(returning: wineserver_is_ready() == 1)
            }
        }
        guard ready else { throw EngineError.wineserverNotReady }
        self.log.append("Wine service process ready.", level: .success)

        let fexOK = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { continuation.resume(returning: fex_initialize()) }
        }
        guard fexOK else { throw EngineError.fexInitFailed }
        self.log.append("CPU translator (FEX) initialized.", level: .success)
    }

    func stopEngineCore() {
        queue.async {
            fex_shutdown()
            wineserver_stop()
        }
    }

    // MARK: - Launch

    /// Preflight + launch. The preflight is real and complete: it checks JIT,
    /// the prefix and the executable, then writes the guest environment the
    /// engine's forks read. Starting the *session host* (the JIT pool, the Metal
    /// presentation layer and input routing) is the remaining port, so this
    /// currently throws `.sessionHostingNotImplemented` with a clear message
    /// rather than pretending to play the game.
    func launch(_ game: InstalledGame) async throws {
        guard !phase.isActive else { throw EngineError.sessionAlreadyRunning }

        // 1. JIT — re-checked on every launch, as required.
        guard JITManager.probeEnabled() else {
            throw EngineError.jitRequired(Self.jitExplanation())
        }

        // 2. Prefix.
        try prefix.createIfNeeded()

        // 3. Executable.
        guard FileManager.default.fileExists(atPath: game.executablePath) else {
            throw EngineError.executableMissing(game.executablePath)
        }

        // 4. Guest environment for the engine's launcher.
        applyLaunchEnvironment(for: game)
        log.append("[launch] preflight passed for \(game.title)")

        phase = .starting
        currentGameID = game.id
        sessionStart = Date()
        GameLibrary.shared.markPlayed(id: game.id)

        // 5. Session host (JIT pool + CAMetalLayer + input) — not ported yet.
        phase = .failed(EngineError.sessionHostingNotImplemented.localizedDescription)
        throw EngineError.sessionHostingNotImplemented
    }

    /// The engine's virtual monitor default before `MADEIRA_SCREEN_W/H` is
    /// applied, and the base a game's render scale is expressed against.
    static let guestBaseResolution = (width: 1280, height: 720)

    /// Write the environment the engine's launcher (`wine_process_start`) reads.
    ///
    /// **Only switch names the pinned forks actually read are written** (see
    /// `docs/ENGINE.md` for the list and its sources). Settings the engine
    /// applies through its own in-process API — the frame cap, the present/sync
    /// mode, the D3D11/D3D12 choice and MetalFX — have no environment variable,
    /// so they are reported here rather than faked; the (unported) session host
    /// is what applies them. Nothing is invented.
    private func applyLaunchEnvironment(for game: InstalledGame) {
        let settings = game.settings

        // MADEIRA_EXE: the program to run. The forks resolve both the PE path
        // and the working folder from it, so it must be a Windows path: a
        // guarded `C:\` path inside the prefix, or a `Z:\` path (Wine's default
        // root mapping) when the executable was installed outside drive_c.
        let guestExe = prefix.windowsPath(forHostPath: game.executablePath)
            ?? Self.rootMappedWindowsPath(forHostPath: game.executablePath)
        setenv("MADEIRA_EXE", guestExe, 1)

        // MADEIRA_ARGS: space-separated extra arguments appended to argv.
        if settings.launchArguments.isEmpty {
            unsetenv("MADEIRA_ARGS")
        } else {
            setenv("MADEIRA_ARGS", settings.launchArguments, 1)
        }

        // The virtual monitor: the engine reads MADEIRA_SCREEN_W/H once per
        // session and MADEIRA_SCREEN_SRC only for its log line.
        let monitor = Self.guestMonitor(scale: settings.resolutionScale)
        setenv("MADEIRA_SCREEN_W", String(monitor.width), 1)
        setenv("MADEIRA_SCREEN_H", String(monitor.height), 1)
        setenv("MADEIRA_SCREEN_SRC", monitor.source, 1)

        // MADEIRA_WORKDIR: the working folder. The forks chdir into it and only
        // honour a `C:\` folder, so anything else is not exported.
        unsetenv("MADEIRA_WORKDIR")
        if let guest = guestWorkingDirectory(for: game) {
            setenv("MADEIRA_WORKDIR", guest, 1)
        }

        // The user's own forks switches, named as the forks name them
        // (FEX_X87REDUCEDPRECISION, MADEIRA_CPU_COUNT, DXMT_D9_ANISO_LIMIT, ...).
        // Windoz never invents a key of its own.
        for (key, value) in settings.environment where !key.isEmpty {
            setenv(key, value, 1)
        }

        // Applied by the engine's in-process API, not the environment. Reported
        // so the log says what this session was configured to do.
        log.append("[launch] frame cap \(settings.fpsCap > 0 ? "\(settings.fpsCap) FPS" : "uncapped"), "
                   + "sync \(settings.syncMode.title), MetalFX \(settings.metalFXUpscaling ? "on" : "off") "
                   + "— applied by the session host, not env")
        log.append("[launch] guest env prepared (exe=\(guestExe), backend=\(settings.graphicsBackend.title))")
    }

    /// A guest Windows path for a folder inside the prefix, or nil. The
    /// per-game `GameSettings.workingDirectory` already is a guest path when the
    /// user set one; `InstalledGame.workingDirectory` is a host path.
    private func guestWorkingDirectory(for game: InstalledGame) -> String? {
        let configured = game.settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isGuestDrivePath(configured) {
            return configured
        }
        guard !game.workingDirectory.isEmpty else { return nil }
        return prefix.windowsPath(forHostPath: game.workingDirectory)
    }

    /// `C:\folder` (or `Z:\folder`) — a path the forks can chdir into.
    private static func isGuestDrivePath(_ path: String) -> Bool {
        guard path.count > 3 else { return false }
        guard let colon = path.firstIndex(of: ":"), path.index(after: colon) < path.endIndex,
              path[path.index(after: colon)] == "\\" else { return false }
        let drive = path[path.startIndex..<colon]
        return drive.count == 1 && drive.first!.isLetter
    }

    /// Wine maps `Z:` to the host root, so a game installed outside the prefix
    /// still has a stable guest path.
    private static func rootMappedWindowsPath(forHostPath host: String) -> String {
        "Z:" + host.replacingOccurrences(of: "/", with: "\\")
    }

    /// The guest monitor size the render scale asks for. The scale is relative
    /// to `guestBaseResolution`; the result is clamped to the range the engine
    /// accepts and kept even-numbered.
    static func guestMonitor(scale: Double) -> (width: Int, height: Int, source: String) {
        let clamped = min(max(scale, 0.25), 4.0)
        func dimension(_ base: Int) -> Int {
            let scaled = Int((Double(base) * clamped).rounded())
            let even = scaled - (scaled % 2)
            return min(max(even, 320), 4096)
        }
        return (dimension(guestBaseResolution.width), dimension(guestBaseResolution.height),
                "windoz:\(String(format: "%.2f", clamped))")
    }

    // MARK: - Stop

    func stop() {
        guard phase.isActive else { return }
        phase = .stopping
        let started = sessionStart
        queue.async { [weak self] in
            fex_shutdown()
            wineserver_stop()
            DispatchQueue.main.async {
                guard let self else { return }
                if let started, let id = self.currentGameID {
                    GameLibrary.shared.addPlaytime(id: id, seconds: Date().timeIntervalSince(started))
                }
                self.sessionStart = nil
                self.currentGameID = nil
                self.phase = .idle
                self.log.append("Session stopped.")
            }
        }
    }
}
