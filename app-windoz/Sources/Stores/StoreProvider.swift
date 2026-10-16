import Foundation

// MARK: - Identifiers and capabilities

enum StoreID: String, Codable, CaseIterable, Identifiable {
    case local
    case steam
    case epic
    case gog
    case rockstar
    case ea

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local games"
        case .steam: return "Steam"
        case .epic: return "Epic Games"
        case .gog: return "GOG"
        case .rockstar: return "Rockstar Games"
        case .ea: return "EA app"
        }
    }

    var symbolName: String {
        switch self {
        case .local: return "folder"
        case .steam: return "gamecontroller"
        case .epic: return "e.square"
        case .gog: return "shippingbox"
        case .rockstar: return "r.square"
        case .ea: return "e.circle"
        }
    }
}

enum SignInStyle: Equatable {
    case native        // Windoz implements the store's sign-in itself
    case externalApp   // sign-in happens inside the vendor's launcher in Wine
    case none          // no account needed (DRM-free / local)
}

enum DownloadChannel: Equatable {
    case native        // Windoz downloads the game's files itself
    case launcher      // the vendor's launcher downloads it, in Wine
    case none

    var title: String {
        switch self {
        case .native: return "In Windoz"
        case .launcher: return "In the official launcher"
        case .none: return "Not applicable"
        }
    }
}

struct StoreCapability: Equatable {
    var signIn: SignInStyle
    var downloads: DownloadChannel
    var library: Bool
    var updateAndVerify: Bool
    var cloudSaves: Bool
    /// True when the vendor's client must run in Wine at game runtime.
    var runtimeLauncherNeeded: Bool
    /// One-line, plain-language summary shown in the Stores screen.
    var summary: String
}

// MARK: - Library model

struct StoreGame: Identifiable, Hashable, Codable {
    var id: String
    var storeID: StoreID
    var title: String
    var subtitle: String?
    var coverURL: URL?
    var heroURL: URL?
    var sizeBytes: Int64?
    var installed: Bool = false
    var needsRuntimeLauncher: Bool = false
    var antiCheat: AntiCheatInfo?
    var compatibility: CompatibilityStatus = .unknown

    var sizeDescription: String? {
        sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

enum StoreAuthState: Equatable {
    case signedOut
    case signingIn(String)
    case signedIn(account: String)
    case error(String)

    var isSignedIn: Bool { if case .signedIn = self { return true }; return false }
}

enum StoreError: LocalizedError {
    case notImplemented(String)
    case notSignedIn
    case network(String)
    case credential
 
    var errorDescription: String? {
        switch self {
        case .notImplemented(let why): return why
        case .notSignedIn: return "Sign in to this store first."
        case .network(let why): return "The store could not be reached: \(why)"
        case .credential: return "The stored sign-in could not be read."
        }
    }
}

// MARK: - The protocol

/// Everything a store must expose. The UI and the download manager only ever
/// see this protocol, so a new store is one file and no UI change.
///
/// Honesty rule: a provider must never report `installed`/`signedIn` unless it
/// really is. Where Windoz cannot yet do the work itself, the provider declares
/// a `.launcher` channel or throws `StoreError.notImplemented` with the reason.
protocol StoreProvider: AnyObject, ObservableObject, Identifiable {
    var id: StoreID { get }
    var capability: StoreCapability { get }
    var authState: StoreAuthState { get }
    var games: [StoreGame] { get }

    /// Begin sign-in. Native stores drive their own flow; launcher stores open
    /// the vendor client in Wine.
    func signIn() async
    func signOut()

    /// Refresh owned games.
    func refreshLibrary() async throws -> [StoreGame]

    func install(_ game: StoreGame) async throws
    func update(_ game: StoreGame) async throws
    func verify(_ game: StoreGame) async throws
    func uninstall(_ game: StoreGame) async throws

    /// Per-game engine settings this store needs (backend, env, args).
    func launchConfiguration(for game: StoreGame) -> GameSettings

    /// Cloud-save sync, where the store offers it.
    func syncCloudSaves(_ game: StoreGame) async throws
}

extension StoreProvider {
    func syncCloudSaves(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("\(id.title) cloud saves are not implemented yet.")
    }
}
