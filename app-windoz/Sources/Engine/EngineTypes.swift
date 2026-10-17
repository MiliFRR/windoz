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

/// Per-game options. These map onto the engine forks' documented switches
/// (see `docs/ENGINE.md`); a key the pinned forks do not read is never written.
struct GameSettings: Codable, Equatable, Hashable {
    /// Render scale relative to the session's logical resolution. 1.0 = native.
    var resolutionScale: Double = 1.0
    /// Frame cap in FPS; 0 means "uncapped" (the engine's -1 / unset).
    var fpsCap: Int = 0
    /// Ask for MetalFX spatial upscaling when the title renders below native.
    var metalFXUpscaling: Bool = false
    /// Present/sync mode.
    var syncMode: SyncMode = .immediate
    /// D3D11 (DXMT) vs native D3D12 selection.
    var graphicsBackend: GraphicsBackend = .auto
    /// Extra environment variables handed to the guest process.
    var environment: [String: String] = [:]
    /// Extra command-line arguments appended to the executable.
    var launchArguments: String = ""
    /// Guest working directory (Windows path or relative-to-drive_c).
    var workingDirectory: String = ""

    static let `default` = GameSettings()
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
    case fexInitFailed
    case sessionAlreadyRunning
    case executableMissing(String)
    case sessionSurfaceTimeout
    case sessionAlreadyRanThisRun
    case wineProcessStartFailed
    case sessionCancelled

    var errorDescription: String? {
        switch self {
        case .jitRequired(let why): return why
        case .prefixMissing: return "The Windows environment has not been set up yet."
        case .prefixCreateFailed(let why): return "The Windows environment could not be created: \(why)"
        case .wineserverStartFailed: return "The Windows service process could not start."
        case .wineserverNotReady: return "The Windows service process started but did not become ready."
        case .fexInitFailed: return "The CPU translator (FEX) failed to initialize."
        case .sessionAlreadyRunning: return "A game session is already running."
        case .executableMissing(let path): return "The game program was not found: \(path)"
        case .sessionSurfaceTimeout:
            return "The game screen never came up: the presentation layer was not ready within 30 seconds. The engine log names what happened."
        case .sessionAlreadyRanThisRun:
            return "Wine can start only one game per app run here — its service process keeps the first session's state. Close Windoz from the app switcher (swipe it away) and open it again to play another game."
        case .wineProcessStartFailed:
            return "The engine could not start the game's process thread. The log has the exact failing step."
        case .sessionCancelled:
            return "The launch was cancelled."
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
