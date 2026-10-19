import Foundation

// MARK: - Health

/// A three-ish-state health value used by the setup wizard and status rows.
/// `.unavailable` always carries a plain-language reason, per the ground rules:
/// never a bare "failed".
enum EngineHealth: Equatable {
    case unknown
    case checking
    case ready
    case unavailable(String)

    var isReady: Bool { if case .ready = self { return true }; return false }

    var shortLabel: String {
        switch self {
        case .unknown: return "—"
        case .checking: return "…"
        case .ready: return "OK"
        case .unavailable: return "Off"
        }
    }

    var reason: String? {
        if case .unavailable(let why) = self { return why }
        return nil
    }
}

/// Whether a Windoz capability is available, with an honest explanation when it
/// is not. Used all over the UI so nothing claims to work when it cannot.
enum FeatureState: Equatable {
    case supported(String?)
    case unavailable(String)
    case notImplemented(String)

    var isSupported: Bool { if case .supported = self { return true }; return false }

    var note: String? {
        switch self {
        case .supported(let n): return n
        case .unavailable(let n): return n
        case .notImplemented(let n): return n
        }
    }
}

// MARK: - JIT

/// How the app is allowed to obtain a JIT-capable debugger attach.
enum JITMethod: String, Codable, CaseIterable, Identifiable {
    case automatic
    case stikDebug
    case builtIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .stikDebug: return "StikDebug"
        case .builtIn: return "Built-in StikJIT"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Use the built-in helper when it is available, otherwise StikDebug."
        case .stikDebug:
            return "Enable JIT through the separate StikDebug app (required inside LiveContainer)."
        case .builtIn:
            return "Enable JIT with Windoz's bundled helper extension. Not available in LiveContainer."
        }
    }
}

// MARK: - Per-game settings

enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    case auto
    case d3d11
    case d3d12

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .d3d11: return "Direct3D 11 (DXMT)"
        case .d3d12: return "Direct3D 12 (native)"
        }
    }
}

enum SyncMode: String, Codable, CaseIterable, Identifiable {
    case immediate
    case mailbox
    case vsync

    var id: String { rawValue }
    var title: String {
        switch self {
        case .immediate: return "Immediate"
        case .mailbox: return "Mailbox"
        case .vsync: return "VSync"
        }
    }
}

/// Frame pacing, mapped onto the engine's own `madeira_set_vsync_locked`
/// values. The pinned engine's front end documents them as
/// `1 = 60, 3 = 30, 4 = 40, 0 = display maximum, 2 = uncapped`
/// (Madeira `Library.swift`, the FPS menu) — these raw values are passed to
/// that call unchanged.
enum FPSLimit: Int, Codable, CaseIterable, Identifiable {
    case displayMaximum = 0
    case sixty = 1
    case uncapped = 2
    case thirty = 3
    case forty = 4

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .displayMaximum: return "Display maximum"
        case .sixty: return "60 FPS"
        case .uncapped: return "Uncapped"
        case .thirty: return "30 FPS"
        case .forty: return "40 FPS"
        }
    }
}

/// Wine's sync engine, as the pins' `MADEIRA_FASTSYNC` variable names it
/// (`auto`, `1`, `cells`, `0`; unset = the engine's own default, which the
/// engine resolves to its fast-sync path).
enum SyncEngineChoice: String, Codable, CaseIterable, Identifiable {
    case engineDefault
    case auto
    case on
    case cells
    case off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .engineDefault: return "Engine default"
        case .auto: return "Auto"
        case .on: return "On"
        case .cells: return "Poll answers only"
        case .off: return "Off (Wine's standard sync)"
        }
    }

    /// nil = leave the variable unset.
    var environmentValue: String? {
        switch self {
        case .engineDefault: return nil
        case .auto: return "auto"
        case .on: return "1"
        case .cells: return "cells"
        case .off: return "0"
        }
    }
}

/// A switch whose engine default is a real third state: leaving the variable
/// unset is different from exporting `0`, so "default" must be selectable.
enum TriState: String, Codable, CaseIterable, Identifiable {
    case engineDefault
    case on
    case off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .engineDefault: return "Engine default"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    /// nil = leave the variable unset.
    var environmentValue: String? {
        switch self {
        case .engineDefault: return nil
        case .on: return "1"
        case .off: return "0"
        }
    }
}

/// How a launch starts the game.
///
/// - `direct` runs the game's own program (everything before 0.4.0). For a
///   Steam game inside the prefix the engine publishes that game's own Steam
///   identity (`MADEIRA_STEAM_APPID`/`MADEIRA_STEAM_APPPATH`), which many
///   steam_api DLLs want even without the client running.
/// - `dock` runs **Doz Dock**: Valve's own Steam client starts inside the
///   session and the game is started through it (`MADEIRA_DOCK_SESSION=1` +
///   the bundled `dockhost.exe`, ported from Madeira's Dock). Steam's own
///   sign-in is handed to the guest once per launch; offline sign-in is
///   Valve's own (offline mode), requested with `MADEIRA_DOCK_OFFLINE`.
/// - `steamDesktop` runs the full Steam client in a virtual desktop for
///   manual sign-in and library use — no game is auto-started.
enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    case direct
    case dock
    case steamDesktop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .direct: return "Direct"
        case .dock: return "Doz Dock (Steam)"
        case .steamDesktop: return "Steam desktop"
        }
    }
}

/// Per-game options. These map onto the engine forks' documented switches
/// (see `docs/ENGINE.md`); a key the pinned forks do not read is never written.
///
/// Decoding is deliberately forgiving (`decodeIfPresent` + defaults): every
/// build that adds an option must not wipe the settings — or the library —
/// written by the build before it.
struct GameSettings: Codable, Equatable, Hashable {
    /// Render scale relative to the session's logical resolution. 1.0 = native.
    var resolutionScale: Double = 1.0
    /// Frame pacing. Applied through the engine's own call
    /// `madeira_set_vsync_locked` — not stored-and-ignored.
    var fpsLimit: FPSLimit = .displayMaximum
    /// Ask for MetalFX spatial upscaling when the title renders below native.
    var metalFXUpscaling: Bool = false
    /// Present/sync mode. No engine switch exists for it in this build.
    var syncMode: SyncMode = .immediate
    /// Wine's sync engine (`MADEIRA_FASTSYNC`).
    var syncEngine: SyncEngineChoice = .engineDefault
    /// D3D11 (DXMT) vs native D3D12 selection. Stored, not applied.
    var graphicsBackend: GraphicsBackend = .auto
    /// Extra environment variables handed to the guest process.
    var environment: [String: String] = [:]
    /// Extra command-line arguments appended to the executable.
    var launchArguments: String = ""
    /// Guest working directory (Windows path or relative-to-drive_c).
    var workingDirectory: String = ""

    // The pins' per-game switches (WineProcessBridge.m's per-launch list,
    // Library.swift's game options). All are applied as environment variables.
    /// AVX/AVX2 through FEX's 128-bit emulation (`MADEIRA_FEX_AVX=1`).
    var fexAVX: Bool = false
    /// Reduced-precision x87 (`FEX_X87REDUCEDPRECISION=1`) — some titles need
    /// it for speed, some for accuracy.
    var reducedX87: Bool = false
    /// `MADEIRA_CPU_COUNT`; 0 = automatic (unset).
    var cpuCount: Int = 0
    /// The host pad as a DirectInput joystick (`MADEIRA_DINPUT_PAD=1`).
    var dinputPad: Bool = false
    /// `DXMT_D9_ANISO_LIMIT`; 0 = automatic (unset), else 1/2/4/8.
    var anisotropyLimit: Int = 0
    /// `MADEIRA_GAME_WINDOWS` — game-mode window handling.
    var gameWindows: TriState = .engineDefault
    /// `MADEIRA_WAIT_CHILDREN=1` — stay in the session while child processes
    /// a launcher started still run.
    var waitChildren: Bool = false
    /// `MADEIRA_VIRTUAL_MODE_SET` — Off exports `0`, which accepts a listed
    /// mode without programming the monitor.
    var virtualModeSet: TriState = .engineDefault
    /// How a launch starts the game (see `LaunchMode`).
    var launchMode: LaunchMode = .direct
    /// Doz Dock only: ask Valve's client for its own offline sign-in
    /// (`MADEIRA_DOCK_OFFLINE=1`) instead of attempting a network logon.
    /// Valve's client decides what it can do offline; this only asks.
    var steamOffline: Bool = false

    static let `default` = GameSettings()
}

extension GameSettings {
    enum CodingKeys: String, CodingKey {
        case resolutionScale, fpsLimit, metalFXUpscaling, syncMode, syncEngine
        case graphicsBackend, environment, launchArguments, workingDirectory
        case fexAVX, reducedX87, cpuCount, dinputPad, anisotropyLimit
        case gameWindows, waitChildren, virtualModeSet
        case launchMode, steamOffline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        resolutionScale = try c.decodeIfPresent(Double.self, forKey: .resolutionScale) ?? d.resolutionScale
        fpsLimit = try c.decodeIfPresent(FPSLimit.self, forKey: .fpsLimit) ?? d.fpsLimit
        metalFXUpscaling = try c.decodeIfPresent(Bool.self, forKey: .metalFXUpscaling) ?? d.metalFXUpscaling
        syncMode = try c.decodeIfPresent(SyncMode.self, forKey: .syncMode) ?? d.syncMode
        syncEngine = try c.decodeIfPresent(SyncEngineChoice.self, forKey: .syncEngine) ?? d.syncEngine
        graphicsBackend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .graphicsBackend) ?? d.graphicsBackend
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? d.environment
        launchArguments = try c.decodeIfPresent(String.self, forKey: .launchArguments) ?? d.launchArguments
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? d.workingDirectory
        fexAVX = try c.decodeIfPresent(Bool.self, forKey: .fexAVX) ?? d.fexAVX
        reducedX87 = try c.decodeIfPresent(Bool.self, forKey: .reducedX87) ?? d.reducedX87
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? d.cpuCount
        dinputPad = try c.decodeIfPresent(Bool.self, forKey: .dinputPad) ?? d.dinputPad
        anisotropyLimit = try c.decodeIfPresent(Int.self, forKey: .anisotropyLimit) ?? d.anisotropyLimit
        gameWindows = try c.decodeIfPresent(TriState.self, forKey: .gameWindows) ?? d.gameWindows
        waitChildren = try c.decodeIfPresent(Bool.self, forKey: .waitChildren) ?? d.waitChildren
        virtualModeSet = try c.decodeIfPresent(TriState.self, forKey: .virtualModeSet) ?? d.virtualModeSet
        launchMode = try c.decodeIfPresent(LaunchMode.self, forKey: .launchMode) ?? d.launchMode
        steamOffline = try c.decodeIfPresent(Bool.self, forKey: .steamOffline) ?? d.steamOffline
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resolutionScale, forKey: .resolutionScale)
        try c.encode(fpsLimit, forKey: .fpsLimit)
        try c.encode(metalFXUpscaling, forKey: .metalFXUpscaling)
        try c.encode(syncMode, forKey: .syncMode)
        try c.encode(syncEngine, forKey: .syncEngine)
        try c.encode(graphicsBackend, forKey: .graphicsBackend)
        try c.encode(environment, forKey: .environment)
        try c.encode(launchArguments, forKey: .launchArguments)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encode(fexAVX, forKey: .fexAVX)
        try c.encode(reducedX87, forKey: .reducedX87)
        try c.encode(cpuCount, forKey: .cpuCount)
        try c.encode(dinputPad, forKey: .dinputPad)
        try c.encode(anisotropyLimit, forKey: .anisotropyLimit)
        try c.encode(gameWindows, forKey: .gameWindows)
        try c.encode(waitChildren, forKey: .waitChildren)
        try c.encode(virtualModeSet, forKey: .virtualModeSet)
        try c.encode(launchMode, forKey: .launchMode)
        try c.encode(steamOffline, forKey: .steamOffline)
    }
}

// MARK: - Compatibility / anti-cheat summary (shown on the game page)

enum CompatibilityStatus: String, Codable, CaseIterable, Identifiable {
    case unknown
    case verified
    case playable
    case runsPoorly
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unknown: return "Untested"
        case .verified: return "Verified"
        case .playable: return "Playable"
        case .runsPoorly: return "Runs poorly"
        case .unsupported: return "Not supported"
        }
    }
}

enum OnlineRisk: String, Codable, CaseIterable {
    case offlineOnly
    case unsupported
    case unknown

    var title: String {
        switch self {
        case .offlineOnly: return "Offline only"
        case .unsupported: return "Online not supported"
        case .unknown: return "Online untested"
        }
    }
}

// MARK: - A game the user can launch

/// An installed game. Store-held games and locally-imported folders both become
/// one of these — the UI and the engine only ever see this type.
///
/// Like `GameSettings`, decoding is forgiving: a file written by an older (or
/// newer) build must never empty the library because one key moved.
struct InstalledGame: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    /// Absolute path (inside the app container) to the Windows executable.
    var executablePath: String
    var workingDirectory: String = ""
    var coverArtPath: String?
    var heroArtPath: String?

    /// Which `StoreProvider` owns this game ("local", "steam", "epic", ...).
    var storeID: String = "local"
    var storeItemID: String?

    var addedAt: Date = Date()
    var lastPlayedAt: Date?
    var playtimeSeconds: Double = 0

    var compatibility: CompatibilityStatus = .unknown
    var antiCheat: AntiCheatInfo?

    var settings: GameSettings = .default
    var cloudSaves: Bool = false
    var requiresOnline: Bool = false

    var execName: String { (executablePath as NSString).lastPathComponent }
}

extension InstalledGame {
    enum CodingKeys: String, CodingKey {
        case id, title, executablePath, workingDirectory, coverArtPath, heroArtPath
        case storeID, storeItemID, addedAt, lastPlayedAt, playtimeSeconds
        case compatibility, antiCheat, settings, cloudSaves, requiresOnline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InstalledGame(title: "", executablePath: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? d.workingDirectory
        coverArtPath = try c.decodeIfPresent(String.self, forKey: .coverArtPath)
        heroArtPath = try c.decodeIfPresent(String.self, forKey: .heroArtPath)
        storeID = try c.decodeIfPresent(String.self, forKey: .storeID) ?? d.storeID
        storeItemID = try c.decodeIfPresent(String.self, forKey: .storeItemID)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? d.addedAt
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        playtimeSeconds = try c.decodeIfPresent(Double.self, forKey: .playtimeSeconds) ?? d.playtimeSeconds
        compatibility = try c.decodeIfPresent(CompatibilityStatus.self, forKey: .compatibility) ?? d.compatibility
        antiCheat = try c.decodeIfPresent(AntiCheatInfo.self, forKey: .antiCheat)
        settings = try c.decodeIfPresent(GameSettings.self, forKey: .settings) ?? d.settings
        cloudSaves = try c.decodeIfPresent(Bool.self, forKey: .cloudSaves) ?? d.cloudSaves
        requiresOnline = try c.decodeIfPresent(Bool.self, forKey: .requiresOnline) ?? d.requiresOnline
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(executablePath, forKey: .executablePath)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(coverArtPath, forKey: .coverArtPath)
        try c.encodeIfPresent(heroArtPath, forKey: .heroArtPath)
        try c.encode(storeID, forKey: .storeID)
        try c.encodeIfPresent(storeItemID, forKey: .storeItemID)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(lastPlayedAt, forKey: .lastPlayedAt)
        try c.encode(playtimeSeconds, forKey: .playtimeSeconds)
        try c.encode(compatibility, forKey: .compatibility)
        try c.encodeIfPresent(antiCheat, forKey: .antiCheat)
        try c.encode(settings, forKey: .settings)
        try c.encode(cloudSaves, forKey: .cloudSaves)
        try c.encode(requiresOnline, forKey: .requiresOnline)
    }
}

// MARK: - Engine status

struct EngineStatus: Equatable {
    var jit: EngineHealth = .unknown
    var memoryEntitlement: EngineHealth = .unknown
    var freeStorageBytes: Int64 = 0
    var runningInLiveContainer: Bool = false
    var jitMethod: JITMethod = .automatic
    /// Earliest date at which the current signing certificate stops working.
    var signingExpiresAt: Date?
    /// Process physical footprint, measured; 0 if the kernel did not report it.
    var memoryFootprintBytes: Int64 = 0
}

// MARK: - Session state

enum SessionPhase: Equatable {
    case idle
    case starting
    case running
    case stopping
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running, .stopping: return true
        case .idle, .failed: return false
        }
    }
}

// MARK: - Errors

enum EngineError: LocalizedError {
    case jitRequired(String)
    case prefixMissing
    case prefixCreateFailed(String)
    case wineserverStartFailed
    case wineserverNotReady
    case jitPoolFailed(String)
    case sessionAlreadyRunning
    case executableMissing(String)
    case sessionSurfaceTimeout
    case sessionAlreadyRanThisRun
    case wineProcessStartFailed
    case sessionCancelled
    case storageRefused(String)
    case sessionStalled(String)
    case engineWedged(String)
    case dockNotReady(String)
    case steamDesktopNotReady(String)

    var errorDescription: String? {
        switch self {
        case .jitRequired(let why): return why
        case .prefixMissing: return "The Windows environment has not been set up yet."
        case .prefixCreateFailed(let why): return "The Windows environment could not be created: \(why)"
        case .wineserverStartFailed: return "The Windows service process could not start."
        case .wineserverNotReady: return "The Windows service process started but did not become ready."
        case .jitPoolFailed(let why): return "The engine's executable memory could not be prepared: \(why)"
        case .sessionAlreadyRunning: return "A game session is already running."
        case .executableMissing(let path): return "The game program was not found: \(path)"
        case .sessionSurfaceTimeout:
            return "The game screen never came up: the presentation layer was not ready within 30 seconds. The engine log names what happened."
        case .sessionAlreadyRanThisRun:
            return "Wine can start only one game per app run here — its service process keeps the first session's state. Use Quit Windoz (Settings → Advanced) to end this app run cleanly, then open Windoz again to play another game."
        case .wineProcessStartFailed:
            return "The engine could not start the game's process thread. The log has the exact failing step."
        case .sessionCancelled:
            return "The launch was cancelled."
        case .storageRefused(let detail):
            return "This device refuses the writes a session needs (\(detail)). Free space: \(AppContainer.freeSpaceDescription()). The launch log's write-audit lines name every location that was probed and the exact error. If every location refused, reinstalling the app inside LiveContainer (fresh container) is the known repair."
        case .sessionStalled(let stage):
            return "The launch stalled at “\(stage)” and the engine is marked spent for this app run. The engine log has the last steps the engine reported; Quit Windoz is the way out."
        case .engineWedged(let why):
            return "The engine is still stuck from the last launch attempt (\(why)) and cannot try again in this app run. Quit Windoz and open the app again."
        case .dockNotReady(let why):
            return "Doz Dock cannot start this launch yet: \(why)"
        case .steamDesktopNotReady(let why):
            return "The Steam desktop session cannot start yet: \(why)"
        }
    }
}

// MARK: - Session outcome

/// What happened to the last session, in plain words, shown on the game page.
/// `crashed` is the engine's own report for the process Windoz started; the
/// status is NTSTATUS-shaped when it is an error (0xC...).
struct SessionOutcome: Equatable {
    var gameTitle: String
    var crashed: Bool
    var status: UInt32
    var seconds: Double
    var message: String
}
