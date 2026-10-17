import Foundation
import Darwin

/// The engine boundary. **Nothing above this file may import Wine, FEX or DXMT
/// symbols.** The UI talks to `WindozEngine` and to plain value types only.
///
/// What is underneath: the pinned engine forks (Wine ARM64EC, FEX-Emu, DXMT and
/// the native D3D12 runtime) driven by the C/ObjC binding layer that those forks
/// require. See `docs/ENGINE.md` for the exact boundary and what each entry
/// point maps to.
///
/// Honesty contract: every method either does the thing it says, or throws an
/// `EngineError` that names the exact missing piece. The session host (the
/// presenting layer, input routing, the guest process) talks to the C glue
/// below through this file only — nothing above it sees an engine symbol.
final class WindozEngine: ObservableObject {
    static let shared = WindozEngine()

    @Published private(set) var status = EngineStatus()
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var currentGameID: UUID?

    /// The game the session screen (rendering + input host) is presenting.
    /// Set right before `.starting`, cleared when the session ends — which is
    /// also what dismisses the session screen.
    @Published private(set) var sessionGame: InstalledGame?
    /// Frames the guest has presented *this session*, read from the engine's
    /// own counter. 0 means "the game has not drawn yet".
    @Published private(set) var sessionFrames: UInt64 = 0
    /// One plain-language line for the in-session overlay.
    @Published private(set) var sessionDetail = ""
    /// The story of the last finished session, for the game page.
    @Published private(set) var lastSessionOutcome: SessionOutcome?
    /// Wine can host one session per app run here (its service process keeps
    /// the first session's registry state). After the first session, launching
    /// asks for a restart instead of pretending a second one works.
    @Published private(set) var sessionsThisRun = 0

    let log = EngineLogStream.shared
    private(set) var prefix: PrefixManager

    private let queue = DispatchQueue(label: "windoz.engine", qos: .userInitiated)
    /// Status probes run on their own queue: they must never wait behind a
    /// long engine-core test (device bug 2026-10-17: the JIT/memory rows sat
    /// at "Checking…" while the core test held `queue`).
    private let probes = DispatchQueue(label: "windoz.probes", qos: .userInitiated)
    private var sessionStart: Date?
    private var callbacksInstalled = false

    /// The surface handshake: the session screen registers its CAMetalLayer
    /// with the engine's display shim and then calls `sessionSurfaceReady()`.
    /// The launch waits for that flag, because the engine's shim resolves the
    /// layer once per process and presenting must not start before it exists.
    private let surfaceLock = NSLock()
    private var sessionSurfaceReadyFlag = false
    private var sessionTimer: Timer?
    private var sawWineProcess = false
    private var sessionBaselineFrames: UInt64 = 0

    /// The session's startup runs on its own queue. The core queue can sit in
    /// a blocking `wineserver_stop()` join; a session must never wait behind
    /// that (device report 2026-10-18: a session stayed at “Preparing the
    /// session…” with no later stage ever running).
    private let sessionQueue = DispatchQueue(label: "windoz.session", qos: .userInitiated)

    /// Fires once a second while a launch is in flight so a stalled startup
    /// (or a session that never draws) becomes an honest message instead of
    /// a black screen that never ends.
    private var launchWatchdog: Timer?
    private var lastStageLine = ""
    /// The frame pacing choice for the running session; re-applied once the
    /// guest's first frame is seen (the engine's own call is the one the
    /// pinned front end uses — see `applyFPSLock`).
    private var launchFPSLimit: FPSLimit = .displayMaximum
    private var fpsReapplied = false

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

    /// Called by the session screen once the presenting CAMetalLayer is on the
    /// window and registered with the engine's display shim. The launch below
    /// waits for this; nothing here invents an ordering of its own.
    func sessionSurfaceReady() {
        surfaceLock.lock()
        sessionSurfaceReadyFlag = true
        surfaceLock.unlock()
        log.append("[session] presentation surface is up.")
    }

    private var sessionSurfaceIsReady: Bool {
        surfaceLock.lock(); defer { surfaceLock.unlock() }
        return sessionSurfaceReadyFlag
    }

    private func resetSessionSurface() {
        surfaceLock.lock(); sessionSurfaceReadyFlag = false; surfaceLock.unlock()
    }

    /// The line the in-session overlay shows, updated by the session poll.
    var sessionHUDLine: String {
        sessionDetail.isEmpty ? "Starting the game…" : sessionDetail
    }

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
        guard !phase.isActive, sessionGame == nil else { throw EngineError.sessionAlreadyRunning }
        guard sessionsThisRun == 0 else { throw EngineError.sessionAlreadyRanThisRun }
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

    /// Preflight + launch, for real: JIT, prefix, executable, the guest
    /// environment, then the session screen (which registers the presenting
    /// Metal layer), then the engine core and the guest process thread. The
    /// session ends when the guest process does — `pollSession` watches for it.
    func launch(_ game: InstalledGame) async throws {
        guard !phase.isActive, sessionGame == nil else { throw EngineError.sessionAlreadyRunning }
        guard sessionsThisRun == 0 else { throw EngineError.sessionAlreadyRanThisRun }

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

        // 4. Storage. Wine writes while it boots (registry, sockets, temp
        //    files); a container that refuses writes would otherwise show up
        //    as a black screen that never ends. This turns that case into a
        //    named refusal *before* the session screen opens.
        try verifySessionStorage()

        // 5. Guest environment for the engine's launcher.
        applyLaunchEnvironment(for: game)
        log.append("[launch] preflight passed for \(game.title)")

        // 6. Hand the game to the session screen. It registers the presenting
        //    CAMetalLayer and calls sessionSurfaceReady(); the launch waits for
        //    that below. The ordering is the engine's requirement: its display
        //    shim resolves the layer once per process, and the guest's first
        //    swapchain must find it already registered.
        resetSessionSurface()
        sessionFrames = 0
        sessionDetail = "Preparing the session…"
        lastStageLine = "Preparing the session…"
        launchFPSLimit = game.settings.fpsLimit
        fpsReapplied = false
        currentGameID = game.id
        sessionStart = Date()
        sessionBaselineFrames = madeira_get_present_count()
        GameLibrary.shared.markPlayed(id: game.id)
        phase = .starting
        sessionGame = game
        log.append("[session] session screen requested.")
        startLaunchWatchdog()

        let surfaceWaitStart = Date()
        let deadline = Date().addingTimeInterval(30)
        while !sessionSurfaceIsReady {
            if Task.isCancelled {
                cancelStartingSession()
                throw EngineError.sessionCancelled
            }
            if Date() >= deadline {
                cancelStartingSession()
                throw EngineError.sessionSurfaceTimeout
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log.append("[session] presentation surface ready after "
                   + String(format: "%.1f", Date().timeIntervalSince(surfaceWaitStart)) + " s.")

        // 7. Start the engine core and the guest process on the session queue:
        //    those calls block (one of them waits up to 60 s for the service
        //    process), so they stay off the main thread — and off the core
        //    queue, which a blocking diagnostics stop can hold.
        let settings = game.settings
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.startGuestProcess(settings: settings)
                    DispatchQueue.main.async {
                        self.sessionsThisRun += 1
                        self.sawWineProcess = false
                        self.phase = .running
                        self.sessionDetail = "Starting the game…"
                        self.lastStageLine = "Starting the game…"
                        self.startSessionPolling()
                        self.log.append("[session] guest process started.")
                    }
                    continuation.resume()
                } catch {
                    DispatchQueue.main.async { self.failStartingSession(error) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on the session queue. Brings the Wine service process and the CPU
    /// translator up if they are not already, sets the frame pacing, resets
    /// the engine's exit report, then starts the guest process thread. Every
    /// step updates the session screen's line so the visible stage is always
    /// the real one.
    private func startGuestProcess(settings: GameSettings) throws {
        // Frame pacing before the process exists — the pinned front end
        // applies its own choice at exactly this point (Madeira
        // `Library.applyEnvironment`).
        applyFPSLock(settings.fpsLimit)

        if wineserver_is_running() == 0 {
            setStage("Starting the Windows service…")
            guard wineserver_start(prefix.url.path) == 0 else { throw EngineError.wineserverStartFailed }
            let deadline = Date().addingTimeInterval(60)
            while wineserver_is_ready() != 1 {
                if Date() >= deadline { throw EngineError.wineserverNotReady }
                Thread.sleep(forTimeInterval: 0.5)
            }
            log.append("Wine service process ready.", level: .success)
        } else {
            setStage("The Windows service is already up.")
        }
        setStage("Starting the CPU translator…")
        guard fex_initialize() else { throw EngineError.fexInitFailed }
        setStage("Launching the game…")
        // The engine reports the exit of the process Windoz hands it through
        // wine_launched_process_did_exit → wine_crash_exit_status; forget the
        // previous session's report first.
        wine_exit_status_reset()
        guard wine_process_start(prefix.url.path) == 0 else { throw EngineError.wineProcessStartFailed }
    }

    /// One line for the session screen and the log, callable from whichever
    /// queue a startup step is on.
    private func setStage(_ text: String) {
        lastStageLine = text
        log.append("[session] \(text)")
        DispatchQueue.main.async {
            if self.phase == .starting { self.sessionDetail = text }
        }
    }

    /// The engine's own frame-pacing call (`madeira_set_vsync_locked`, the
    /// one the pinned front end's FPS menu uses). Resolved at runtime so a
    /// build without the symbol degrades to an honest log line instead of a
    /// link failure. Values are the engine's: 1 = 60, 3 = 30, 4 = 40,
    /// 0 = display maximum, 2 = uncapped.
    private typealias VsyncLockFn = @convention(c) (Int32) -> Void
    private static let vsyncLock: VsyncLockFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_set_vsync_locked") else { return nil }
        return unsafeBitCast(symbol, to: VsyncLockFn.self)
    }()

    private func applyFPSLock(_ limit: FPSLimit) {
        guard let lock = Self.vsyncLock else {
            log.append("[session] frame pacing: this engine build does not export madeira_set_vsync_locked — the choice stays stored",
                       level: .warning)
            return
        }
        lock(Int32(limit.rawValue))
        log.append("[session] frame pacing set to \(limit.title) (madeira_set_vsync_locked(\(limit.rawValue))).",
                   level: .success)
    }

    /// Wine writes while it boots. If the container refuses every write, the
    /// launch refuses too, with the reason — instead of a black screen that
    /// never ends (device report 2026-10-18).
    private func verifySessionStorage() throws {
        let targets: [(name: String, url: URL)] = [
            ("prefix", prefix.url),
            ("drive_c", prefix.url.appendingPathComponent("drive_c")),
            ("tmp", AppContainer.temporary),
        ]
        var refused: [String] = []
        var writable = 0
        for (name, dir) in targets {
            if AppContainer.acceptsWrites(dir) { writable += 1 } else { refused.append(name) }
        }
        log.append("[launch] storage check: \(writable)/\(targets.count) locations accepted a write"
                   + (refused.isEmpty ? "" : " — refused: \(refused.joined(separator: ", "))"))
        if writable == 0 {
            throw EngineError.storageRefused(refused.joined(separator: ", "))
        }
    }

    /// Watches a launch from the main thread: a stalled startup, or a session
    /// that never draws a frame, becomes an honest message instead of an
    /// endless black screen. Budgets are generous — a first boot (service
    /// cold start + translator + the game's own loader) is genuinely slow.
    private func startLaunchWatchdog() {
        launchWatchdog?.invalidate()
        launchWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkLaunchWatchdog()
        }
        launchWatchdog?.tolerance = 0.3
    }

    private func checkLaunchWatchdog() {
        guard sessionGame != nil || phase.isActive, let start = sessionStart else {
            launchWatchdog?.invalidate(); launchWatchdog = nil
            return
        }
        let age = Date().timeIntervalSince(start)
        switch phase {
        case .starting where age > 180:
            failStartingSession(EngineError.sessionStalled(lastStageLine.isEmpty ? "starting" : lastStageLine))
        case .running where sessionFrames == 0 && age > 300:
            launchWatchdog?.invalidate(); launchWatchdog = nil
            detachSession(reason: "\(sessionGame?.title ?? "The game") did not draw a frame within five minutes")
        case .running where sessionFrames > 0:
            launchWatchdog?.invalidate(); launchWatchdog = nil
        default:
            break
        }
    }

    /// The launch failed before the guest process started: take the session
    /// screen down and leave the message where the game page shows it.
    private func failStartingSession(_ error: Error) {
        sessionTimer?.invalidate(); sessionTimer = nil
        launchWatchdog?.invalidate(); launchWatchdog = nil
        let message = (error as? EngineError)?.localizedDescription ?? error.localizedDescription
        phase = .failed(message)
        sessionGame = nil
        sessionDetail = ""
        currentGameID = nil
        sessionStart = nil
        log.append("[session] \(message)", level: .error)
    }

    /// The session screen went away mid-launch and the launch was cancelled.
    /// If the guest process had already made it out, it keeps running (only an
    /// app restart ends it) — so the session is detached, honestly, rather
    /// than abandoned silently.
    private func cancelStartingSession() {
        sessionTimer?.invalidate(); sessionTimer = nil
        launchWatchdog?.invalidate(); launchWatchdog = nil
        if wineserver_is_running() != 0 && wine_process_is_running() != 0 {
            detachSession(reason: "The launch screen closed after the game process had already started.")
        } else {
            phase = .idle
            sessionGame = nil
            sessionDetail = ""
            currentGameID = nil
            sessionStart = nil
            log.append("[session] launch cancelled before the process started.")
        }
    }

    /// The engine's virtual monitor default before `MADEIRA_SCREEN_W/H` is
    /// applied, and the base a game's render scale is expressed against.
    static let guestBaseResolution = (width: 1280, height: 720)

    /// Write the environment the engine's launcher (`wine_process_start`) reads.
    ///
    /// **Only switch names the pinned forks actually read are written** (see
    /// `docs/ENGINE.md` for the list and its sources). The frame pacing goes
    /// through the engine's own call (`madeira_set_vsync_locked`) at session
    /// start. What has neither a variable nor an engine call this build can
    /// make — the present/mailbox mode, MetalFX upscaling and the D3D11/D3D12
    /// backend choice — is stored and *said to be stored*. Nothing is invented.
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

        // Per-game engine switches. All of them are variables the pinned forks
        // read (WineProcessBridge.m's per-launch list and Library.swift's game
        // options). Controlled keys are always set *or* unset, so a previous
        // launch's choice can never leak into this one.
        func switchVar(_ name: String, _ value: String?) {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        switchVar("MADEIRA_FASTSYNC", settings.syncEngine.environmentValue)
        switchVar("FEX_X87REDUCEDPRECISION", settings.reducedX87 ? "1" : nil)
        switchVar("MADEIRA_FEX_AVX", settings.fexAVX ? "1" : nil)
        switchVar("MADEIRA_CPU_COUNT", (1..<64).contains(settings.cpuCount) ? String(settings.cpuCount) : nil)
        switchVar("MADEIRA_DINPUT_PAD", settings.dinputPad ? "1" : nil)
        switchVar("DXMT_D9_ANISO_LIMIT", [1, 2, 4, 8].contains(settings.anisotropyLimit)
            ? String(settings.anisotropyLimit) : nil)
        switchVar("MADEIRA_GAME_WINDOWS", settings.gameWindows.environmentValue)
        switchVar("MADEIRA_WAIT_CHILDREN", settings.waitChildren ? "1" : nil)
        switchVar("MADEIRA_VIRTUAL_MODE_SET", settings.virtualModeSet.environmentValue)

        // The user's own forks switches, named as the forks name them
        // (FEX_X87REDUCEDPRECISION, MADEIRA_CPU_COUNT, DXMT_D9_ANISO_LIMIT, ...).
        // Windoz never invents a key of its own; these apply last so an expert
        // entry can override the switches above.
        for (key, value) in settings.environment where !key.isEmpty {
            setenv(key, value, 1)
        }

        // Reported, with the truth about where each one stands this build.
        log.append("[launch] frame pacing \(settings.fpsLimit.title) → the engine's own call at session start; "
                   + "sync engine \(settings.syncEngine.title), x87 \(settings.reducedX87 ? "reduced" : "default"), "
                   + "AVX \(settings.fexAVX ? "on" : "default"), CPUs \(settings.cpuCount == 0 ? "auto" : String(settings.cpuCount)), "
                   + "aniso \(settings.anisotropyLimit == 0 ? "default" : String(settings.anisotropyLimit)) → environment")
        log.append("[launch] present mode \(settings.syncMode.title), MetalFX \(settings.metalFXUpscaling ? "on" : "off"), "
                   + "backend \(settings.graphicsBackend.title) — stored, not applied (no engine switch for them in this build)")
        log.append("[launch] guest env prepared (exe=\(guestExe))")
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

    // MARK: - Session end

    /// Watch the guest process from the main thread. `wine_process_is_running`
    /// drops when the engine's process thread is done; that thread also stops
    /// the service process at its end, so both at zero is the honest
    /// end-of-session signal.
    private func startSessionPolling() {
        sessionTimer?.invalidate()
        sawWineProcess = false
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollSession()
        }
        sessionTimer?.tolerance = 0.15
    }

    private func pollSession() {
        guard sessionGame != nil || phase.isActive else {
            sessionTimer?.invalidate(); sessionTimer = nil
            return
        }
        let raw = madeira_get_present_count()
        sessionFrames = raw >= sessionBaselineFrames ? raw - sessionBaselineFrames : raw
        if sessionFrames > 0 && !fpsReapplied {
            // Re-apply now that the guest's swapchain exists — the same call
            // the pinned front end makes from its FPS menu.
            fpsReapplied = true
            applyFPSLock(launchFPSLimit)
        }
        if wine_process_is_running() != 0 {
            sawWineProcess = true
            sessionDetail = sessionFrames > 0
                ? "Rendering — \(sessionFrames) frame\(sessionFrames == 1 ? "" : "s") presented."
                : "The game is starting (no frame yet)."
        } else if sawWineProcess && wineserver_is_running() == 0 {
            finishSession()
        } else if !sawWineProcess, let start = sessionStart,
                  Date().timeIntervalSince(start) > 90, wineserver_is_running() == 0 {
            finishSession(early: true)
        }
    }

    /// The single end-of-session path: playtime is recorded once, the engine's
    /// exit report is read, the session screen is dismissed and the story is
    /// kept for the game page.
    private func finishSession(early: Bool = false) {
        sessionTimer?.invalidate(); sessionTimer = nil
        launchWatchdog?.invalidate(); launchWatchdog = nil
        var status: UInt32 = 0
        let crashed = wine_crash_exit_status(&status) == 1
        let title = sessionGame?.title ?? "The game"
        let seconds = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        if let id = currentGameID {
            GameLibrary.shared.addPlaytime(id: id, seconds: seconds)
        }

        let body: String
        if crashed {
            body = "\(title) ended with an error (status 0x\(String(status, radix: 16, uppercase: true))). The engine log has the details."
        } else if early {
            body = "\(title) stopped before its first frame — the engine log names what happened."
        } else {
            body = "\(title) has exited."
        }
        let message = body + " Wine can start only one game per app run — close Windoz from the app switcher and open it again to play another game."
        lastSessionOutcome = SessionOutcome(gameTitle: sessionGame?.title ?? "", crashed: crashed,
                                            status: status, seconds: seconds, message: message)
        log.append("[session] \(message)")
        sessionGame = nil
        sessionDetail = ""
        currentGameID = nil
        sessionStart = nil
        phase = .idle
    }

    /// Ask the game to close (Alt+F4). The guest's own save-and-exit path
    /// runs; the session ends when its process does.
    func requestQuit() {
        guard sessionGame != nil || phase.isActive else { return }
        phase = .stopping
        sessionDetail = "Close requested — the game should save and exit."
        winios_post_key(0x12, 1)                 // Alt down
        winios_post_key(0x73, 1)                 // F4 down
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            winios_post_key(0x73, 0)
            winios_post_key(0x12, 0)
        }
        log.append("[session] close requested (Alt+F4).")
    }

    /// Leave the session from Windoz's side. Honest about the rest: Wine's
    /// service process keeps running until the app ends, and the one-session
    /// per run rule stands. Never calls `wineserver_stop()` here — the guest
    /// thread owns that call at its end, and joining the service thread twice
    /// is not safe.
    func detachSession(reason: String? = nil) {
        guard sessionGame != nil || phase.isActive else { return }
        sessionTimer?.invalidate(); sessionTimer = nil
        launchWatchdog?.invalidate(); launchWatchdog = nil
        let title = sessionGame?.title ?? "The game"
        let seconds = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        if let id = currentGameID {
            GameLibrary.shared.addPlaytime(id: id, seconds: seconds)
        }
        let message = (reason.map { $0 + " " } ?? "")
            + "Windoz left the session screen. If \(title) is still running it ends when Windoz does — Wine can host one session per app run here."
        lastSessionOutcome = SessionOutcome(gameTitle: sessionGame?.title ?? "", crashed: false,
                                            status: 0, seconds: seconds, message: message)
        log.append("[session] \(message)")
        sessionGame = nil
        sessionDetail = ""
        currentGameID = nil
        sessionStart = nil
        phase = .idle
    }

    // MARK: - Stop

    /// Stop what the app is doing. A live game session is asked to close and
    /// then detached (see `detachSession`); the guest thread stops the service
    /// process itself. Before any session, this shuts the core services down.
    func stop() {
        if sessionGame != nil || phase.isActive {
            requestQuit()
            detachSession(reason: "Stop was pressed.")
            return
        }
        guard sessionsThisRun == 0 else {
            log.append("Nothing to stop: the Wine service process is owned by the session that already ran.")
            return
        }
        queue.async {
            fex_shutdown()
            wineserver_stop()
        }
        log.append("Engine core stopped.")
    }
}
