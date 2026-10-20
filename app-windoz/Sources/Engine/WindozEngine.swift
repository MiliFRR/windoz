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
    /// Doz Dock's live progress while a dock session runs: what Valve's client
    /// is doing right now, read from the host's report file. Nil when the
    /// session is not a dock session or the host has not reported yet.
    @Published private(set) var dockStage: String?
    /// The honest failure reason while a dock session still runs (the host's
    /// report carries it before the session ends). Nil when there is none.
    @Published private(set) var dockFailure: String?
    /// The story of the last finished session, for the game page.
    @Published private(set) var lastSessionOutcome: SessionOutcome?
    /// Wine can host one session per app run here (its service process keeps
    /// the first session's registry state). After the first session, launching
    /// asks for a restart instead of pretending a second one works.
    @Published private(set) var sessionsThisRun = 0
    /// The launch pipeline's steps, live: the session screen shows them while
    /// a launch runs, and the game page shows them when one fails.
    @Published private(set) var launchSteps: [LaunchStep] = []
    /// The most recent launch that failed, for the game page's failure card:
    /// the failing step, one suggested repair, the log tail behind Share.
    /// Cleared when the next launch starts.
    @Published private(set) var lastFailedLaunch: LaunchFailure?
    /// Set when a launch stalls inside the engine's start-up and the app run
    /// is spent: the stuck thread holds the engine's init lock, so another
    /// attempt in this process would wedge the same way. Only a new process
    /// clears it — the failure card and Settings both offer Quit Windoz.
    @Published private(set) var engineWedged = false

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
    /// Set by Cancel while a launch has not reached a guest process yet; the
    /// surface wait notices it and unwinds through `cancelStartingSession`.
    private var launchCancelRequested = false
    /// Why the run is spent, in the failing stage's own words.
    private var wedgeReason = ""
    /// Set once a launch is abandoned (stalled, cancelled or failed): a stuck
    /// debugger exchange that answers late must not quietly start the guest
    /// behind the app's back.
    private var sessionAbandoned = false
    /// Exactly-one-resume handles for the guest-start continuation, so the
    /// stall budget and Cancel can each unwind it safely.
    private var guestStartGuard: ContinuationGuard?
    private var guestStartContinuation: CheckedContinuation<Void, Error>?
    /// The frame pacing choice for the running session; re-applied once the
    /// guest's first frame is seen (the engine's own call is the one the
    /// pinned front end uses — see `applyFPSLock`).
    private var launchFPSLimit: FPSLimit = .displayMaximum
    private var fpsReapplied = false
    /// Set once the no-frame watchdog has spoken; drives the session screen's
    /// wording. A game that is still loading is never force-closed — the
    /// owner decides.
    private var noFrameWarned = false

    /// The frame-stall detector: after the first frame, a guest that stops
    /// presenting is worth one honest log line and one geometry re-publish
    /// (a rotation can leave DXMT's swapchain sized for the old surface). It
    /// never closes the game: a paused title or a long load is not a failure.
    private var lastPresentedFrames: UInt64 = 0
    private var lastFrameAdvanceAt: Date?
    private var frameStallWarned = false

    /// Doz Dock's validated game and its one-use hand-in path. `prepareLaunchMode`
    /// writes the transfer and sets `MADEIRA_DOCK_AUTH_FILE`; the environment
    /// builder clears every dock variable before re-arming the mode, so the
    /// hand-in path must be put back explicitly. Without it the host has no
    /// sign-in to give Valve's client — the launch looked healthy and then
    /// failed inside the session.
    private var dockGameForLaunch: DozDock.Game?
    private var dockHandoffPath: String?

    /// `madeira_set_eco` / `madeira_get_eco` (Madeira's low-QoS guest-thread
    /// mode). Resolved at runtime like the frame-pacing call, so a pinned
    /// engine that does not export them degrades to an honest log line.
    @Published private(set) var ecoEnabled = false
    private typealias EcoSetFn = @convention(c) (Int32) -> Void
    private typealias EcoGetFn = @convention(c) () -> Int32
    private static let ecoSet: EcoSetFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_set_eco") else { return nil }
        return unsafeBitCast(symbol, to: EcoSetFn.self)
    }()
    private static let ecoGet: EcoGetFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_get_eco") else { return nil }
        return unsafeBitCast(symbol, to: EcoGetFn.self)
    }()
    var ecoIsAvailable: Bool { Self.ecoSet != nil }


    init(prefix: PrefixManager = PrefixManager()) {
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
            return "JIT was enabled, but the debugger is no longer attached — the engine's JIT requests need one to answer them. Enable JIT again (Settings › JIT setup) and keep the debugger attached."
        }
        if AppEnvironment.isLiveContainer {
            return "JIT is off. Inside LiveContainer, turn on “Launch with JIT”, point its script at Documents/LiveContainer/windoz-jit.js, then attach StikDebug (Windoz's bundled helper cannot be used here)."
        }
        return "JIT is off. Open Settings › JIT setup to attach StikDebug or Windoz's bundled helper, then try again."
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

    /// Start the engine's core services (the Wine service process and this
    /// run's executable-memory pool) without a game. This is the part that is
    /// fully wired and is what the diagnostics screen exercises on device.
    func startEngineCore() async throws {
        guard !phase.isActive, sessionGame == nil else { throw EngineError.sessionAlreadyRunning }
        guard sessionsThisRun == 0 else { throw EngineError.sessionAlreadyRanThisRun }
        try prefix.createIfNeeded()

        let poolOK = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { continuation.resume(returning: JITPool.ensure()) }
        }
        guard poolOK else {
            throw EngineError.jitPoolFailed(JITPool.failure ?? "the JIT pool could not be allocated")
        }
        self.log.append("Executable memory pool ready (\(JITPool.sizeMB) MB).", level: .success)

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
    }

    func stopEngineCore() {
        queue.async {
            wineserver_stop()
        }
    }

    // MARK: - Launch

    /// Preflight + launch, for real: JIT, prefix, executable, the guest
    /// environment, then the session screen (which registers the presenting
    /// Metal layer), then the engine core and the guest process thread. The
    /// session ends when the guest process does — `pollSession` watches for it.
    ///
    /// Every stage is a visible step (`launchSteps`): the session screen and
    /// the failure card on the game page read the same list, so "where did the
    /// launch stop" is never a guess.
    func launch(_ game: InstalledGame) async throws {
        guard !engineWedged else {
            throw EngineError.engineWedged(wedgeReason.isEmpty ? "the previous launch stalled" : wedgeReason)
        }
        guard !phase.isActive, sessionGame == nil else { throw EngineError.sessionAlreadyRunning }
        guard sessionsThisRun == 0 else { throw EngineError.sessionAlreadyRanThisRun }

        launchCancelRequested = false
        sessionAbandoned = false
        onMain { self.lastFailedLaunch = nil }
        beginLaunchSteps()

        do {
            // 1. JIT — re-checked on every launch, as required. When the
            //    built-in helper is the chosen method, one silent attempt is
            //    made here: it attaches without leaving Windoz and without
            //    user input. StikDebug cannot attach silently (it opens
            //    another app), so its path stays a button in JIT setup.
            startStep(LaunchStepID.jit)
            if !JITManager.probeEnabled(), await JITCoordinator.shared.autoEnableIfPossible() {
                EngineLogStream.shared.append("[jit] attached before launch through the built-in helper.", level: .success)
            }
            guard JITManager.probeEnabled() else {
                throw EngineError.jitRequired(Self.jitExplanation())
            }
            finishStep(LaunchStepID.jit, detail: Self.jitStepDetail())

            // 2. Prefix.
            startStep(LaunchStepID.prefix)
            try prefix.createIfNeeded()
            finishStep(LaunchStepID.prefix, detail: prefix.url.path)

            // 2b. Windows runtimes — information, never a gate: what the prefix
            //     has, what is missing and where it is installed. Offline is
            //     allowed and the game starts anyway (Phase 5).
            startStep(LaunchStepID.runtimes)
            if let runtimeNotice = await RuntimeInstaller.shared.launchNotice(prefix: prefix) {
                finishStep(LaunchStepID.runtimes, detail: runtimeNotice)
            } else {
                finishStep(LaunchStepID.runtimes, detail: "The runtimes Windoz tracks are in place or provided by the engine.")
            }

            // 3. Executable. Only a direct launch runs the game's own program —
            //    the Steam modes run Valve's client, which finds the game itself.
            startStep(LaunchStepID.exe)
            if game.settings.launchMode == .direct {
                guard FileManager.default.fileExists(atPath: game.executablePath) else {
                    throw EngineError.executableMissing(game.executablePath)
                }
                finishStep(LaunchStepID.exe, detail: game.execName)
            } else {
                skipStep(LaunchStepID.exe, why: "\(game.settings.launchMode.title) starts the game through Steam itself.")
            }

            // 4. Storage. Wine writes while it boots (registry, sockets, temp
            //    files); a container that refuses writes would otherwise show up
            //    as a black screen that never ends. This turns that case into a
            //    named refusal *before* the session screen opens. The write test
            //    is the same probe the storage negotiation ran, so the prefix's
            //    own location is judged exactly as it was chosen.
            startStep(LaunchStepID.storage)
            try verifySessionStorage()
            finishStep(LaunchStepID.storage, detail: "The prefix and its drive_c accept writes.")

            // 5. Launch mode + guest environment for the engine's launcher.
            //    Doz Dock's contract (host, client files, Steam's own install
            //    record, the one-use sign-in transfer) is validated here — a
            //    missing piece must be a named refusal, never a black screen.
            startStep(LaunchStepID.mode)
            try prepareLaunchMode(for: game)
            applyLaunchEnvironment(for: game)
            finishStep(LaunchStepID.mode, detail: modeStepDetail(game))
            log.append("[launch] preflight passed for \(game.title)")

            // 6. Hand the game to the session screen. It registers the presenting
            //    CAMetalLayer and calls sessionSurfaceReady(); the launch waits for
            //    that below. The ordering is the engine's requirement: its display
            //    shim resolves the layer once per process, and the guest's first
            //    swapchain must find it already registered.
            startStep(LaunchStepID.surface)
            resetSessionSurface()
            // Publish on the main thread: the launch body runs off the main
            // actor, and off-main `@Published` writes made SwiftUI updates
            // unreliable — which read as a launch screen that never moves.
            onMain {
                self.sessionFrames = 0
                self.sessionDetail = "Preparing the session…"
                self.lastStageLine = "Preparing the session…"
                self.dockStage = nil
                self.dockFailure = nil
                self.launchFPSLimit = game.settings.fpsLimit
                self.fpsReapplied = false
                self.noFrameWarned = false
                self.currentGameID = game.id
                self.sessionStart = Date()
                self.sessionBaselineFrames = madeira_get_present_count()
                GameLibrary.shared.markPlayed(id: game.id)
                self.phase = .starting
                self.sessionGame = game
                self.log.append("[session] session screen requested.")
                self.startLaunchWatchdog()
            }

            let surfaceWaitStart = Date()
            let deadline = Date().addingTimeInterval(30)
            while !sessionSurfaceIsReady {
                if Task.isCancelled || launchCancelRequested {
                    cancelStartingSession()
                    throw EngineError.sessionCancelled
                }
                if Date() >= deadline {
                    cancelStartingSession()
                    throw EngineError.sessionSurfaceTimeout
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            finishStep(LaunchStepID.surface,
                       detail: "Up in " + String(format: "%.1f", Date().timeIntervalSince(surfaceWaitStart)) + " s.")
            log.append("[session] presentation surface ready after "
                       + String(format: "%.1f", Date().timeIntervalSince(surfaceWaitStart)) + " s.")

            // 7. Start the guest process on the session queue: the JIT pool,
            //    Wine service and guest calls block (the service waits up to
            //    60 s), so they stay off the main thread — and off the core
            //    queue, which a blocking diagnostics stop can hold. The guest
            //    path marks its own pool and service steps in execution order.
            let settings = game.settings
            let guardBox = ContinuationGuard()
            guestStartGuard = guardBox
            defer {
                guestStartGuard = nil
                guestStartContinuation = nil
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guestStartContinuation = continuation
                sessionQueue.async {
                    do {
                        try self.startGuestProcess(settings: settings)
                        DispatchQueue.main.async {
                            guard self.phase == .starting, self.sessionGame != nil else {
                                // The launch was cancelled or declared stalled
                                // while the guest was being started. A real
                                // process may exist anyway — never leave it
                                // untracked.
                                if wine_process_is_running() != 0 {
                                    self.sessionsThisRun += 1
                                    self.phase = .running
                                    self.detachSession(reason: "The launch was cancelled while the game process was starting.")
                                }
                                return
                            }
                            self.sessionsThisRun += 1
                            self.sawWineProcess = false
                            self.phase = .running
                            self.sessionDetail = "Starting the game…"
                            self.lastStageLine = "Starting the game…"
                            self.startSessionPolling()
                            self.log.append("[session] guest process started.")
                            self.finishStep(LaunchStepID.guest, detail: "The game's process thread is running.")
                            self.startStep(LaunchStepID.frame, detail: "Waiting for the first frame…")
                        }
                        if guardBox.claim() { continuation.resume() }
                    } catch {
                        if guardBox.claim() {
                            DispatchQueue.main.async { self.failStartingSession(error) }
                            continuation.resume(throwing: error)
                        }
                    }
                }
                // The guest-start stall budget. The known wedge: the CPU
                // translator waits on the debugger's JIT script with the
                // engine's init lock held, so this stage never returns. The
                // resume below is what turns "frozen on the launch screen
                // forever" into a named failure with the Quit path.
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.guestStartBudget) { [weak self] in
                    guard let self, guardBox.claim() else { return }
                    DispatchQueue.main.async {
                        let reason = self.lastStageLine.isEmpty ? "the start-up stage never finished" : self.lastStageLine
                        self.wedgeAndFail(reason)
                        self.failStartingSession(EngineError.sessionStalled(reason))
                        continuation.resume(throwing: EngineError.sessionStalled(reason))
                    }
                }
            }
        } catch {
            // The only place a failure becomes an entry: preflight steps and
            // the guest startup both unwind here, exactly once.
            if !Self.isCancellation(error) {
                recordLaunchFailure(game: game, error: error)
            }
            throw error
        }
    }

    // MARK: - Launch steps

    /// Seconds since the launch began, for the start screen's elapsed clock.
    var sessionElapsed: TimeInterval {
        sessionStart.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func beginLaunchSteps() {
        onMain { self.launchSteps = LaunchStep.pipeline() }
    }

    /// Publish engine state on the main thread. The launch body runs off the
    /// main actor (it awaits the engine's blocking calls), so every write the
    /// UI reads comes through here — off-main `@Published` writes made SwiftUI
    /// updates unreliable, which read as a frozen launch screen.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func updateStep(_ id: String, _ change: @escaping (inout LaunchStep) -> Void) {
        let apply = {
            if let index = self.launchSteps.firstIndex(where: { $0.id == id }) {
                change(&self.launchSteps[index])
            }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func startStep(_ id: String, detail: String = "") {
        updateStep(id) { step in
            step.state = .running
            step.detail = detail
            step.startedAt = Date()
        }
    }

    private func finishStep(_ id: String, detail: String? = nil) {
        updateStep(id) { step in
            step.state = .done
            if let detail { step.detail = detail }
            step.finishedAt = Date()
        }
    }

    private func skipStep(_ id: String, why: String) {
        updateStep(id) { step in
            step.state = .skipped(why)
            step.detail = why
            step.finishedAt = Date()
        }
    }

    private func failStep(_ id: String, message: String) {
        updateStep(id) { step in
            step.state = .failed(message)
            step.detail = message
            step.finishedAt = Date()
        }
    }

    /// Record a failed launch for the game page: mark whichever step was
    /// running, keep the message, and attach a suggested repair. Called from
    /// the launch task's only catch, so a launch is never double-recorded.
    private func recordLaunchFailure(game: InstalledGame, error: Error) {
        let message = (error as? EngineError)?.localizedDescription ?? error.localizedDescription
        onMain {
            let runningIndex = self.launchSteps.lastIndex { step in
                if case .running = step.state { return true }
                return false
            }
            if let index = runningIndex {
                self.failStep(self.launchSteps[index].id, message: message)
            }
            self.lastFailedLaunch = LaunchFailure(
                gameID: game.id,
                gameTitle: game.title,
                message: message,
                hint: Self.launchHint(for: error),
                failedStep: runningIndex.map { self.launchSteps[$0].title })
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        guard let engineError = error as? EngineError else { return false }
        if case .sessionCancelled = engineError { return true }
        return false
    }

    /// One suggested repair per failure — short, concrete, never "an unknown
    /// error occurred". Nil when there is nothing honest to suggest.
    private static func launchHint(for error: Error) -> String? {
        guard let engineError = error as? EngineError else {
            return "Try again. If it repeats, share this report — it carries the launch steps and the log tail."
        }
        switch engineError {
        case .jitRequired:
            return "Settings → JIT switches JIT back on; it turns off every time the app restarts."
        case .executableMissing:
            return "The recorded program path no longer exists. Re-import the game, or correct the path in this game's settings."
        case .storageRefused:
            return "This device refused the writes a session needs. Restarting LiveContainer — or reinstalling Windoz inside it — is the known repair."
        case .prefixMissing, .prefixCreateFailed:
            return "Advanced settings has Create / Repair for the Windows environment."
        case .sessionSurfaceTimeout:
            return "Retry once. If the screen still never comes up, share this report — the steps above say how far the launch got."
        case .wineserverStartFailed, .wineserverNotReady, .jitPoolFailed, .wineProcessStartFailed:
            return "Retry once. If it repeats, use Quit Windoz (Settings → Advanced), open the app again and retry; share this report if it still fails."
        case .sessionAlreadyRanThisRun, .sessionAlreadyRunning:
            return "Quit Windoz (Settings → Advanced, or the button above) and open it again."
        case .engineWedged:
            return "Quit Windoz — the button above — then open the app again."
        case .sessionStalled:
            return "Quit Windoz and open the app again, then retry. If the stall was at the JIT memory step, the debugger did not answer the engine — re-attach JIT (Settings → JIT setup) before retrying."
        case .dockNotReady, .steamDesktopNotReady:
            return "The message above names the exact missing piece; this game's settings can switch the launch mode."
        case .sessionCancelled:
            return nil
        }
    }

    private static func jitStepDetail() -> String {
        if AppEnvironment.isSimulator { return "Simulator build" }
        if AppEnvironment.isLiveContainer { return "Debugger attached — LiveContainer launched this app with JIT" }
        return "Debugger attached"
    }

    private func modeStepDetail(_ game: InstalledGame) -> String {
        switch game.settings.launchMode {
        case .direct: return "Direct start: \(game.execName)"
        case .dock: return "Doz Dock — Valve's client starts the game; sign-in transfer ready"
        case .steamDesktop: return "Steam desktop — sign in inside the session"
        }
    }

    /// Cancel a launch that has not reached the guest process yet (the start
    /// screen's Cancel button). Once a guest exists, cancelling becomes
    /// "leave the session, honestly" — Wine cannot un-start a process here.
    func cancelLaunch() {
        guard phase.isActive || sessionGame != nil else { return }
        if wine_process_is_running() != 0 {
            requestQuit()
            detachSession(reason: "The launch was cancelled from the start screen after the game process had started — Windoz asked it to close.")
            return
        }
        launchCancelRequested = true
        if phase == .starting {
            cancelStartingSession()
        }
        log.append("[session] launch cancelled from the start screen.")
    }

    /// Runs on the session queue. Grants the JIT pool, detaches the debugger,
    /// brings the Wine service up, sets the frame pacing, resets the engine's
    /// exit report, then starts the guest process thread. Every step updates
    /// the session screen's line so the visible stage is always the real one.
    private func startGuestProcess(settings: GameSettings) throws {
        guard !sessionAbandoned else { throw EngineError.sessionCancelled }
        // Frame pacing before the process exists — the pinned front end
        // applies its own choice at exactly this point (Madeira
        // `Library.applyEnvironment`).
        applyFPSLock(settings.fpsLimit)

        // Madeira's order, exactly: the debugger grants the JIT pool, the
        // debugger leaves, the Wine service starts, the guest starts. The
        // pool's three environment variables are the engine's own contract
        // (virtual_ios.c reads them); without this step the guest has no
        // executable memory and the launch screen never gets past black.
        startStep(LaunchStepID.pool, detail: "Asking the debugger for executable memory…")
        setStage("Preparing executable memory…")
        guard JITPool.ensure() else {
            let why = JITPool.failure ?? "the JIT pool could not be allocated"
            failStep(LaunchStepID.pool, message: why)
            throw EngineError.jitPoolFailed(why)
        }
        finishStep(LaunchStepID.pool, detail: "\(JITPool.sizeMB) MB granted to the engine.")
        guard !sessionAbandoned else { throw EngineError.sessionCancelled }
        setStage("Detaching the debugger…")
        JITPool.detachDebugger()

        startStep(LaunchStepID.service, detail: "Waiting for Wine's service process.")
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
        finishStep(LaunchStepID.service, detail: "Wine's service process is ready.")
        // An abandoned attempt (stall budget or Cancel) must not quietly
        // start the guest when the pool finally answers.
        guard !sessionAbandoned else { throw EngineError.sessionCancelled }
        // Eco belongs to the guest threads; apply it after the service is up
        // and before the game's process exists.
        applyEcoAtSessionStart()
        setStage("Launching the game…")
        startStep(LaunchStepID.guest, detail: "Starting the game's process thread…")
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
            // The checklist's live line belongs to whichever step is running;
            // the service, pool and guest steps run one at a time.
            if let index = self.launchSteps.firstIndex(where: { $0.state == .running }) {
                self.launchSteps[index].detail = text
            }
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

    // MARK: - Eco mode

    /// Apply the engine's low-QoS guest-thread mode live. Eco trades speed for
    /// power: loading screens finish later but the SoC keeps its thermal
    /// budget for gameplay. The choice is an app preference, so the next
    /// session starts the same way.
    func setEco(_ enabled: Bool, persist: Bool = true) {
        if persist { SessionPreferences.ecoMode = enabled }
        guard let set = Self.ecoSet else {
            ecoEnabled = false
            log.append("[session] eco mode: this engine build does not export madeira_set_eco — the switch is unavailable.",
                       level: .warning)
            return
        }
        set(enabled ? 1 : 0)
        ecoEnabled = enabled
        log.append("[session] eco mode \(enabled ? "on" : "off") (madeira_set_eco(\(enabled ? 1 : 0))).",
                   level: enabled ? .success : .info)
    }

    /// Called on the session queue right before the guest process exists, so
    /// the choice applies to the threads that start the game.
    private func applyEcoAtSessionStart() {
        let enabled = SessionPreferences.ecoMode
        Self.ecoSet?(enabled ? 1 : 0)
        DispatchQueue.main.async { self.ecoEnabled = Self.ecoSet == nil ? false : enabled }
        if Self.ecoSet == nil {
            log.append("[session] eco mode unavailable: this engine build does not export madeira_set_eco.", level: .warning)
        } else {
            log.append("[session] eco mode \(enabled ? "on" : "off") for this session (madeira_set_eco).")
        }
    }

    /// Eco belongs to a running guest. Once the session is over, put the app's
    /// own threads back to normal even though the preference stays saved.
    private func disableEcoForIdle() {
        guard Self.ecoSet != nil else { return }
        if Self.ecoGet?() != 0 { Self.ecoSet?(0) }
        if ecoEnabled { ecoEnabled = false }
    }

    /// True while the running session was started through Doz Dock; the
    /// launch report is only read afterwards, and only then.
    private var dockSessionActive = false

    /// The launch mode's preflight, run before the session screen opens.
    /// Every refusal here is a named `EngineError` — nothing is left to a
    /// black screen to reveal.
    private func prepareLaunchMode(for game: InstalledGame) throws {
        switch game.settings.launchMode {
        case .direct:
            dockSessionActive = false
            dockGameForLaunch = nil
            dockHandoffPath = nil
            DozDock.cleanup()
        case .dock:
            guard let dockGame = DozDock.game(for: game, prefix: prefix) else {
                throw EngineError.dockNotReady("this game's Steam install record was not found in Steam's library inside Windows. Install the game from Windoz's Steam library (new installs land in Steam's own folder), or switch this game to Direct in its settings.")
            }
            try DozDock.validate(dockGame, prefix: prefix)
            let stored = SteamTokenStore().loadTokens()
            guard let account = stored?.accountName, !account.isEmpty,
                  let token = stored?.refreshToken, !token.isEmpty else {
                throw EngineError.dockNotReady("Windoz has no Steam sign-in to hand to Valve's client. Sign in to Steam in Windoz first (Steam library → sign-in), then start the game.")
            }
            let handoff = try DozDock.writeHandoff(account: account, token: token, appID: dockGame.id, prefix: prefix)
            dockGameForLaunch = dockGame
            dockHandoffPath = handoff
            dockSessionActive = true
            log.append("[dock] preflight passed for app \(dockGame.id) — sign-in transfer ready (protected file), host bundled")
        case .steamDesktop:
            dockSessionActive = false
            dockGameForLaunch = nil
            dockHandoffPath = nil
            DozDock.cleanup()
            let root = prefix.url.appendingPathComponent("drive_c/\(SteamClientRuntime.relativeRoot)")
            let required = ["steam.exe", "steamclient64.dll", "steamclient.dll"]
            let missing = required.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            guard missing.isEmpty else {
                throw EngineError.steamDesktopNotReady("Valve's Steam client files are incomplete in the Windows drive (missing: \(missing.joined(separator: ", "))). In this game's settings, under “Steam launch”, download Steam's components first (about 72 MB from Valve's own CDN).")
            }
            do {
                try SteamClientRuntime.writeDesktopLauncher(driveC: prefix.url.appendingPathComponent("drive_c"))
            } catch {
                throw EngineError.steamDesktopNotReady("The Steam desktop launcher could not be written into the Windows drive (\(error.localizedDescription)). Check the prefix's free space and permissions, then try again.")
            }
            log.append("[launch] Steam desktop preflight passed — steam.exe and both client DLLs are present.")
        }
    }

    /// Wine writes while it boots. Each location a session depends on is
    /// probed with the same create + write + replace test the storage
    /// negotiation used. The gate passes when the prefix and its `drive_c`
    /// accept writes — those are the folders a session lives in. A refusal
    /// carries every location's exact answer; the error text adds the free
    /// space, because "out of space" and "permission refused" need different
    /// repairs.
    private func verifySessionStorage() throws {
        let targets: [(name: String, url: URL)] = [
            ("prefix", prefix.url),
            ("drive_c", prefix.url.appendingPathComponent("drive_c")),
            ("storage root", AppContainer.storageRoot),
        ]
        var lines: [String] = []
        var prefixOK = false, driveOK = false
        for (name, dir) in targets {
            let verdict = AppContainer.probeWrites(dir, label: name)
            lines.append("\(name): \(verdict.summary)")
            if verdict.usable {
                if name == "prefix" { prefixOK = true }
                if name == "drive_c" { driveOK = true }
            } else if name != "prefix" && name != "drive_c" {
                log.append("[launch] storage: \(name) refused (\(verdict.summary))", level: .warning)
            }
        }
        log.append("[launch] storage check: \(prefixOK && driveOK ? "passed" : "refused") — "
                   + lines.joined(separator: "; "))
        guard prefixOK && driveOK else {
            throw EngineError.storageRefused(lines.joined(separator: "; "))
        }
    }

    /// Watches a launch from the main thread: a stalled startup becomes an
    /// honest failure with the last stage's name, and a session that draws no
    /// frame for five minutes gets a spoken warning — but is never force-closed,
    /// because a first boot (service cold start + translator + the game's own
    /// loader) is genuinely slow. Budgets are generous for the same reason.
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
            let reason = lastStageLine.isEmpty ? "the start-up stage never finished" : lastStageLine
            wedgeAndFail(reason)
            failStartingSession(EngineError.sessionStalled(reason))
        case .running where sessionFrames == 0 && age > 300 && !noFrameWarned:
            // Say it on the session screen and in the log; the owner decides.
            // The warning is the last thing this timer has to offer: the
            // session timer watches the process from here, so stop burning a
            // tick every second on a question nobody is asking any more.
            noFrameWarned = true
            log.append("[session] no frame in five minutes — the game may still be loading; the startup stages are in this log", level: .warning)
            launchWatchdog?.invalidate(); launchWatchdog = nil
        case .running where sessionFrames > 0:
            launchWatchdog?.invalidate(); launchWatchdog = nil
        default:
            break
        }
    }

    /// The launch has made no progress for the full budget and its thread is
    /// stuck inside the engine (the debugger exchange for the JIT pool is the
    /// known case). The engine's start-up lock is held by that thread, so this
    /// app run cannot host another attempt: mark it spent — every later
    /// attempt gets the named refusal instead of wedging again — and stop what
    /// can be stopped.
    private func wedgeAndFail(_ reason: String) {
        engineWedged = true
        wedgeReason = reason
        sessionsThisRun += 1
        sessionAbandoned = true
        log.append("[session] the launch is wedged at “\(reason)” — this app run cannot try again; Quit Windoz is the repair.", level: .error)
        teardownWedgedEngine()
    }

    /// Stop the pieces of a wedged start-up that can be stopped. The guest
    /// process never started (that is what wedged means here), so only the
    /// service process needs to go — it is the part that burns CPU with
    /// nothing to do. Nothing here calls into the in-process FEX bridge:
    /// Madeira's launch path does not use it, and the pool itself belongs to
    /// the process, not the session.
    private func teardownWedgedEngine() {
        guard wine_process_is_running() == 0 else { return }
        queue.async {
            self.log.append("[session] stopping the Windows service after the stalled launch", level: .warning)
            wineserver_stop()
        }
    }

    /// The launch failed before the guest process started: take the session
    /// screen down and leave the message where the game page shows it.
    private func failStartingSession(_ error: Error) {
        sessionAbandoned = true
        disableEcoForIdle()
        clearDockLaunchState()
        sessionTimer?.invalidate(); sessionTimer = nil
        launchWatchdog?.invalidate(); launchWatchdog = nil
        let message = (error as? EngineError)?.localizedDescription ?? error.localizedDescription
        phase = .failed(message)
        sessionGame = nil
        sessionDetail = ""
        currentGameID = nil
        sessionStart = nil
        log.append("[session] \(message)", level: .error)
        EngineLogFile.shared.appendEngineLogTail(reason: "the launch failed")
    }

    /// The session screen went away mid-launch and the launch was cancelled.
    /// If the guest process had already made it out, it keeps running (only an
    /// app restart ends it) — so the session is detached, honestly, rather
    /// than abandoned silently.
    private func cancelStartingSession() {
        sessionAbandoned = true
        disableEcoForIdle()
        // Unwind the guest-start continuation if that is the stuck piece —
        // without this, Cancel during a wedged start-up would leave the Play
        // button busy forever.
        if let guardBox = guestStartGuard, guardBox.claim() {
            guestStartContinuation?.resume(throwing: EngineError.sessionCancelled)
        }
        onMain {
            self.sessionTimer?.invalidate(); self.sessionTimer = nil
            self.launchWatchdog?.invalidate(); self.launchWatchdog = nil
            if wineserver_is_running() != 0 && wine_process_is_running() != 0 {
                self.detachSession(reason: "The launch screen closed after the game process had already started.")
            } else {
                if self.phase.isActive || self.sessionGame != nil {
                    self.log.append("[session] launch cancelled before the process started.")
                }
                self.clearDockLaunchState()
                self.phase = .idle
                self.sessionGame = nil
                self.sessionDetail = ""
                self.currentGameID = nil
                self.sessionStart = nil
            }
        }
    }

    /// The engine's virtual monitor default before `MADEIRA_SCREEN_W/H` is
    /// applied, and the base a game's render scale is expressed against.
    static let guestBaseResolution = (width: 1280, height: 720)

    /// How long the guest-start stage may run without finishing before the
    /// run is declared spent. The service wait inside it is itself bounded at
    /// 60 s; the debugger's pool request (a BRK exchange) is the only other
    /// step that can wait, and an unanswered request is a refusal, not a hang.
    private static let guestStartBudget: TimeInterval = 160

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
        let monitor = Self.guestMonitor(resolution: settings.resolution, scale: settings.resolutionScale)

        // Swap memory lives in the engine, not here: the bridge recreates the
        // file-backed tier whenever madeira.cfg asks for it. Say what the next
        // session will arm so the log answers "was swap on?" without a guess.
        let swap = MadeiraConfig.readSwap()
        if swap.isOff {
            log.append("[launch] swap tier off (Documents/madeira.cfg has no swap-mb)")
        } else {
            log.append("[launch] swap tier requested: \(swap.sizeMB) MB, coverage \(swap.coverage.rawValue) — Documents/madeira.cfg")
        }

        // Every launch starts from a clean slate: the dock variables are
        // always set *or* unset by the branch below, so a dock session and a
        // direct session can never leak into each other.
        DozDock.clearEnvironment()
        unsetenv("MADEIRA_DESKTOP")
        unsetenv("MADEIRA_WORKDIR")

        // The virtual monitor: the engine reads MADEIRA_SCREEN_W/H once per
        // session and MADEIRA_SCREEN_SRC only for its log line.
        setenv("MADEIRA_SCREEN_W", String(monitor.width), 1)
        setenv("MADEIRA_SCREEN_H", String(monitor.height), 1)
        setenv("MADEIRA_SCREEN_SRC", monitor.source, 1)

        // MADEIRA_EXE / MADEIRA_ARGS / MADEIRA_WORKDIR, per launch mode.
        switch settings.launchMode {
        case .dock:
            // Doz Dock: Valve's client's host — an explorer virtual desktop
            // running C:\windows\system32\dockhost.exe — starts the game
            // through Steam itself. The sign-in transfer and the host's
            // environment were validated and prepared in `prepareLaunchMode`.
            setenv("MADEIRA_EXE", "explorer.exe", 1)
            setenv("MADEIRA_ARGS", DozDock.launchArguments(width: monitor.width, height: monitor.height), 1)
            setenv("MADEIRA_DESKTOP", "1", 1)
            setenv("MADEIRA_DOCK_SESSION", "1", 1)
            setenv("MADEIRA_GDI_SHARED_SECTION", "1", 1)
            setenv("MADEIRA_JIT_IMAGE_RETIRE", "1", 1)
            setenv("MADEIRA_IMAGE_MAP_GUARD", "1", 1)
            setenv("MADEIRA_DESKTOP_FIT", "1", 1)
            unsetenv("MADEIRA_STEAM_APPID")
            unsetenv("MADEIRA_STEAM_APPPATH")
            // `DozDock.clearEnvironment()` above deliberately clears every
            // dock variable, including the one-use sign-in path. Put the
            // validated hand-in back: without it the host starts, Valve's
            // client asks for a sign-in, and the launch fails inside the
            // session with no useful message.
            if let dockGame = dockGameForLaunch {
                DozDock.configure(dockGame)
            }
            if let dockHandoffPath {
                setenv("MADEIRA_DOCK_AUTH_FILE", dockHandoffPath, 1)
            }
            let offline = DozDock.Offline.apply(requested: settings.steamOffline)
            log.append("[launch] Doz Dock session: MADEIRA_DOCK_SESSION=1, sign-in transfer "
                       + (dockHandoffPath == nil ? "MISSING" : "armed")
                       + ", Valve's client starts app \(game.storeItemID ?? "?") itself. "
                       + (offline ? "Offline sign-in requested (MADEIRA_DOCK_OFFLINE=1) — Valve's client decides what it can do offline."
                                  : "Online sign-in (MADEIRA_DOCK_OFFLINE unset)."))
        case .steamDesktop:
            // The full Windows Steam client in a virtual desktop, for manual
            // sign-in and library use. No game is auto-started. The client is
            // a launcher that reloads and forks its own modules, so it needs
            // the same desktop-session switches Doz Dock uses: parked module
            // images that can be retired, the shared GDI section, the image
            // map guard, and child processes kept in-session. It must not be
            // given the fixed Steam identity either — Valve's own client is
            // the identity here.
            // Madeira's proven Steam desktop path: explorer starts a command on
            // the shell desktop; the command runs a batch that starts the SCM
            // first and then Valve's client with the CEF flags. Starting
            // steam.exe directly left its Chromium UI without services/rpcss.
            setenv("MADEIRA_EXE", "explorer.exe", 1)
            setenv("MADEIRA_ARGS", "/desktop=shell,\(monitor.width)x\(monitor.height) cmd /c \(SteamClientRuntime.desktopLauncherPath)", 1)
            unsetenv("MADEIRA_WORKDIR")
            setenv("MADEIRA_DESKTOP", "1", 1)
            setenv("MADEIRA_DOCK_SESSION", "1", 1)
            setenv("MADEIRA_GDI_SHARED_SECTION", "1", 1)
            setenv("MADEIRA_JIT_IMAGE_RETIRE", "1", 1)
            setenv("MADEIRA_IMAGE_MAP_GUARD", "1", 1)
            setenv("MADEIRA_DESKTOP_FIT", "1", 1)
            unsetenv("MADEIRA_STEAM_APPID")
            unsetenv("MADEIRA_STEAM_APPPATH")
            log.append("[launch] Steam desktop session: explorer.exe runs /desktop=shell,\(monitor.width)x\(monitor.height) cmd /c \(SteamClientRuntime.desktopLauncherPath); the batch starts services.exe, then steam.exe with the CEF sandbox/GPU flags, on the dock desktop switches. Sign in inside the session — the password never passes through Windoz.")
        case .direct:
            // MADEIRA_EXE: the program to run. The forks resolve both the PE
            // path and the working folder from it, so it must be a Windows
            // path: a guarded `C:\` path inside the prefix, or a `Z:\` path
            // (Wine's default root mapping) when the executable was installed
            // outside drive_c.
            let guestExe = prefix.windowsPath(forHostPath: game.executablePath)
                ?? Self.rootMappedWindowsPath(forHostPath: game.executablePath)
            setenv("MADEIRA_EXE", guestExe, 1)

            // MADEIRA_ARGS: space-separated extra arguments appended to argv.
            if settings.launchArguments.isEmpty {
                unsetenv("MADEIRA_ARGS")
            } else {
                setenv("MADEIRA_ARGS", settings.launchArguments, 1)
            }

            // MADEIRA_WORKDIR: the working folder. The forks chdir into it and
            // only honour a `C:\` folder, so anything else is not exported.
            if let guest = guestWorkingDirectory(for: game) {
                setenv("MADEIRA_WORKDIR", guest, 1)
            }

            // Steam identity for a direct start: when the game's program sits
            // inside the prefix, the engine publishes SteamAppPath /
            // SteamGameId / SteamAppId for *this* game (its guard wants an
            // appid of digits and a `C:\` folder path). Without it the
            // engine's own fixed fallback identity would be published.
            var identity = "none"
            if game.storeID == "steam", let raw = game.storeItemID, let appID = Int(raw),
               DozDock.validAppID(appID),
               let exePath = prefix.windowsPath(forHostPath: game.executablePath) {
                let folder = (exePath as NSString).deletingLastPathComponent
                if folder.uppercased().hasPrefix("C:\\") && !folder.contains("..") && folder.count < 1024 {
                    setenv("MADEIRA_STEAM_APPID", String(appID), 1)
                    setenv("MADEIRA_STEAM_APPPATH", folder, 1)
                    identity = "\(appID) (SteamAppPath=\(folder))"
                }
            }
            if identity == "none" {
                unsetenv("MADEIRA_STEAM_APPID"); unsetenv("MADEIRA_STEAM_APPPATH")
            }
            log.append("[launch] direct start: exe=\(guestExe), Steam identity \(identity)")
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

        // Valve's own client is a launcher: it forks helper processes and
        // relaunches parts of itself. Keeping children alive is not optional
        // there, so the full Steam desktop forces it on. A user environment
        // entry can still override this below, as with every other switch.
        if settings.launchMode == .steamDesktop {
            setenv("MADEIRA_WAIT_CHILDREN", "1", 1)
        }

        // The user's own forks switches, named as the forks name them
        // (FEX_X87REDUCEDPRECISION, MADEIRA_CPU_COUNT, DXMT_D9_ANISO_LIMIT, ...).
        // Windoz never invents a key of its own; these apply last so an expert
        // entry can override the switches above.
        for (key, value) in settings.environment where !key.isEmpty {
            setenv(key, value, 1)
        }

        // Reported, with the truth about where each one stands this build.
        log.append("[launch] guest monitor \(monitor.width)×\(monitor.height) (\(monitor.source)); "
                   + "keyboard-and-mouse joystick: on-screen WASD keys")
        log.append("[launch] controller API: XInput always; DirectInput joystick \(settings.dinputPad ? "on (MADEIRA_DINPUT_PAD=1)" : "off")")
        log.append("[launch] frame pacing \(settings.fpsLimit.title) → the engine's own call at session start; "
                   + "sync engine \(settings.syncEngine.title), x87 \(settings.reducedX87 ? "reduced" : "default"), "
                   + "AVX \(settings.fexAVX ? "on" : "default"), CPUs \(settings.cpuCount == 0 ? "auto" : String(settings.cpuCount)), "
                   + "aniso \(settings.anisotropyLimit == 0 ? "default" : String(settings.anisotropyLimit)) → environment")
        log.append("[launch] present mode \(settings.syncMode.title), MetalFX \(settings.metalFXUpscaling ? "on" : "off"), "
                   + "backend \(settings.graphicsBackend.title) — stored, not applied (no engine switch for them in this build)")
        log.append("[launch] guest env prepared (mode=\(settings.launchMode.title))")
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

    /// The guest monitor size a session asks for. A named preset uses its exact
    /// pixels; `.scaled` keeps the pre-0.9 behaviour (1280×720 times the
    /// per-game render scale). Every result is clamped to the range the engine
    /// accepts and kept even-numbered.
    static func guestMonitor(resolution: GameResolution, scale: Double) -> (width: Int, height: Int, source: String) {
        func dimension(_ value: Int) -> Int {
            let even = value - (value % 2)
            return min(max(even, 320), 4096)
        }
        if let size = resolution.size {
            return (dimension(size.width), dimension(size.height), "preset:\(resolution.rawValue)")
        }
        let clamped = min(max(scale, 0.25), 4.0)
        func scaledDimension(_ base: Int) -> Int {
            dimension(Int((Double(base) * clamped).rounded()))
        }
        return (scaledDimension(guestBaseResolution.width), scaledDimension(guestBaseResolution.height),
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
        lastPresentedFrames = 0
        lastFrameAdvanceAt = nil
        frameStallWarned = false
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
        let now = Date()
        if sessionFrames != lastPresentedFrames {
            lastPresentedFrames = sessionFrames
            lastFrameAdvanceAt = now
            frameStallWarned = false
        } else if sessionFrames > 0, !frameStallWarned,
                  let last = lastFrameAdvanceAt, now.timeIntervalSince(last) > 12 {
            // A rotation can leave the swapchain sized for the old surface.
            // Ask the session host to publish its geometry once more; if that
            // is not the cause, the log still says exactly when frames
            // stopped. The game is never killed here.
            frameStallWarned = true
            log.append("[session] no new frame for 12 s at \(sessionFrames) presented — re-publishing the display geometry. The process is still running.", level: .warning)
            NotificationCenter.default.post(name: .windozSessionDisplayRefresh, object: nil)
        }
        if sessionFrames > 0 && !fpsReapplied {
            // Re-apply now that the guest's swapchain exists — the same call
            // the pinned front end makes from its FPS menu.
            fpsReapplied = true
            applyFPSLock(launchFPSLimit)
        }
        if sessionFrames > 0,
           let index = launchSteps.firstIndex(where: { $0.id == LaunchStepID.frame }),
           launchSteps[index].state == .running {
            finishStep(LaunchStepID.frame,
                       detail: "First frame after " + String(format: "%.1f", sessionElapsed) + " s.")
        }
        if dockSessionActive { updateDockProgress() }
        if wine_process_is_running() != 0 {
            sawWineProcess = true
            sessionDetail = frameStallWarned && sessionFrames > 0
                ? "No new frame for 12 s (still running). The display was refreshed once; if it stays frozen, the log has the exact stage."
                : (sessionFrames > 0
                   ? "Rendering — \(sessionFrames) frame\(sessionFrames == 1 ? "" : "s") presented."
                   : (noFrameWarned
                      ? "No frame in five minutes — the game may still be loading. It keeps running if you leave; the log has the startup stages."
                      : "The game is starting (no frame yet)."))
        } else if sawWineProcess && wineserver_is_running() == 0 {
            finishSession()
        } else if !sawWineProcess, let start = sessionStart,
                  Date().timeIntervalSince(start) > 90, wineserver_is_running() == 0 {
            finishSession(early: true)
        }
    }

    /// Live Doz Dock progress. The host appends its numeric report to
    /// `C:\madeira-dock.txt` while the session runs; read it every poll and
    /// turn the newest stage into words. A refusal is shown the moment the
    /// report names it, while the session still runs — a slow first launch
    /// used to look like a stall until the session ended.
    private func updateDockProgress() {
        let fields = DozDock.readReport(prefix: prefix)
        if fields.isEmpty, dockStage == nil { return }
        if let failure = DozDock.humanFailure(fields) {
            if dockFailure != failure {
                dockFailure = failure
                log.append("[dock] Valve's client refused the launch: \(failure)", level: .warning)
            }
        } else if dockFailure != nil {
            dockFailure = nil
        }
        let stage = DozDock.progressStage(fields)
        if dockStage != stage { dockStage = stage }
    }

    /// Reads Doz Dock's report (once) when the session that just ended was a
    /// dock session: logs every field the host wrote, returns the honest
    /// failure reason when Valve's client reported one, and removes the
    /// one-use sign-in transfer along with the dock environment.
    private func takeDockReportNote() -> String? {
        guard dockSessionActive else { return nil }
        let fields = DozDock.readReport(prefix: prefix)
        dockSessionActive = false
        clearDockLaunchState()
        return DozDock.humanFailure(fields)
    }

    /// Remove the one-use sign-in transfer and forget the validated dock game.
    /// Called on every path that ends or abandons a launch, so a token is
    /// never left in the prefix for a session that did not use it.
    private func clearDockLaunchState() {
        dockSessionActive = false
        dockGameForLaunch = nil
        dockHandoffPath = nil
        DozDock.cleanup()
    }

    /// The single end-of-session path: playtime is recorded once, the engine's
    /// exit report is read, the session screen is dismissed and the story is
    /// kept for the game page.
    private func finishSession(early: Bool = false) {
        sessionTimer?.invalidate(); sessionTimer = nil
        launchWatchdog?.invalidate(); launchWatchdog = nil
        disableEcoForIdle()
        var status: UInt32 = 0
        let crashed = wine_crash_exit_status(&status) == 1
        let title = sessionGame?.title ?? "The game"
        let seconds = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        if let id = currentGameID {
            GameLibrary.shared.addPlaytime(id: id, seconds: seconds)
        }

        // A Doz Dock session writes its numeric report into the prefix; read
        // it once, here, so the outcome the game page shows carries the
        // honest reason when Valve's client refused something.
        let dockNote = takeDockReportNote()

        let body: String
        if crashed {
            body = "\(title) ended with an error (status 0x\(String(status, radix: 16, uppercase: true))). The engine log has the details."
        } else if early {
            body = "\(title) stopped before its first frame — the engine log names what happened."
        } else {
            body = "\(title) has exited."
        }
        let message = body + (dockNote.map { " " + $0 } ?? "")
            + " Wine can start only one game per app run — close Windoz from the app switcher and open it again to play another game."
        lastSessionOutcome = SessionOutcome(gameTitle: sessionGame?.title ?? "", crashed: crashed,
                                            status: status, seconds: seconds, message: message)
        log.append("[session] \(message)")
        EngineLogFile.shared.appendEngineLogTail(reason: "the session ended")
        sessionGame = nil
        sessionDetail = ""
        dockStage = nil
        dockFailure = nil
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
        disableEcoForIdle()
        sessionTimer?.invalidate(); sessionTimer = nil
        launchWatchdog?.invalidate(); launchWatchdog = nil
        let title = sessionGame?.title ?? "The game"
        let seconds = sessionStart.map { Date().timeIntervalSince($0) } ?? 0
        if let id = currentGameID {
            GameLibrary.shared.addPlaytime(id: id, seconds: seconds)
        }
        let dockNote = takeDockReportNote()
        let message = (reason.map { $0 + " " } ?? "")
            + (dockNote.map { $0 + " " } ?? "")
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
            wineserver_stop()
        }
        log.append("Engine core stopped.")
    }
}

/// Exactly-one resume for the guest-start continuation: the session queue's
/// work block, the stall budget and Cancel can each finish first, and a
/// second resume of the same continuation would trap (the same pattern as the
/// Steam session's logon guard).
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
