import Foundation
import Combine

// MARK: - Local folder

/// "Add local game": import an executable from Files or a mounted network share.
/// This is the only provider that is fully functional today, because it needs no
/// store account and no vendor launcher.
final class LocalFolderStore: ObservableObject, StoreProvider {
    let id: StoreID = .local

    let capability = StoreCapability(
        signIn: .none,
        downloads: .none,
        library: true,
        updateAndVerify: false,
        cloudSaves: false,
        runtimeLauncherNeeded: false,
        summary: "Import a Windows game from Files or a network share. DRM-free games work best; the app detects any anti-cheat it ships with.")

    @Published var authState: StoreAuthState = .signedOut
    @Published var games: [StoreGame] = []

    private var cancellable: AnyCancellable?

    init() {
        refreshFromLibrary()
        cancellable = GameLibrary.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshFromLibrary() }
        }
    }

    private func refreshFromLibrary() {
        games = GameLibrary.shared.games
            .filter { $0.storeID == StoreID.local.rawValue }
            .map(Self.storeGame)
    }

    static func storeGame(_ game: InstalledGame) -> StoreGame {
        StoreGame(id: game.id.uuidString, storeID: .local, title: game.title,
                  subtitle: game.execName, coverURL: nil, heroURL: nil,
                  sizeBytes: Self.folderSize(game.workingDirectory),
                  installed: true, needsRuntimeLauncher: false,
                  antiCheat: game.antiCheat, compatibility: game.compatibility)
    }

    /// Import an executable that is already inside the app container (the caller
    /// copies it there first — Files URLs are security-scoped).
    @discardableResult
    func importExecutable(at url: URL, title: String? = nil) throws -> InstalledGame {
        let folder = url.deletingLastPathComponent()
        let antiCheat = AntiCheatDetector.detect(inFolder: folder.path)
        var game = InstalledGame(title: title ?? url.deletingPathExtension().lastPathComponent,
                                 executablePath: url.path,
                                 workingDirectory: folder.path,
                                 coverArtPath: Self.findCover(in: folder)?.path,
                                 storeID: StoreID.local.rawValue)
        game.antiCheat = antiCheat
        game.compatibility = Self.compatibility(for: antiCheat)
        GameLibrary.shared.add(game)
        return game
    }

    func signIn() async {}
    func signOut() {}

    func refreshLibrary() async throws -> [StoreGame] { games }

    func install(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Add local games with the import button — there is nothing to download.")
    }
    func update(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Local games are updated by replacing their files; Windoz does not manage that.")
    }
    func verify(_ game: StoreGame) async throws {
        guard let installed = installedGame(game) else { throw StoreError.notImplemented("This game is no longer in the library.") }
        guard FileManager.default.fileExists(atPath: installed.executablePath) else {
            throw StoreError.network("The game's program file is missing at \(installed.execName).")
        }
    }
    func uninstall(_ game: StoreGame) async throws {
        guard let installed = installedGame(game) else { return }
        GameLibrary.shared.remove(id: installed.id)
    }

    func launchConfiguration(for game: StoreGame) -> GameSettings {
        GameSettings.default
    }

    // MARK: - helpers

    private func installedGame(_ game: StoreGame) -> InstalledGame? {
        guard let uuid = UUID(uuidString: game.id) else { return nil }
        return GameLibrary.shared.game(withID: uuid)
    }

    private static func compatibility(for antiCheat: AntiCheatInfo?) -> CompatibilityStatus {
        guard let antiCheat else { return .unknown }
        return antiCheat.onlineRisk == .unsupported ? .unsupported : .playable
    }

    private static func findCover(in folder: URL) -> URL? {
        let candidates = ["cover.jpg", "cover.png", "folder.jpg", "folder.png", "library_600x900.jpg"]
        for name in candidates {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func folderSize(_ path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        var total: Int64 = 0
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen > 20000 { break }
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true, let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total > 0 ? total : nil
    }
}

// MARK: - Epic

/// Native Epic. Chunked downloads and updates follow the Legendary/Heroic
/// approach; titles that refuse to start without the official client fall back
/// to the Epic Games Launcher in Wine.
final class EpicStore: ObservableObject, StoreProvider {
    let id: StoreID = .epic

    let capability = StoreCapability(
        signIn: .native,
        downloads: .native,
        library: true,
        updateAndVerify: true,
        cloudSaves: true,
        runtimeLauncherNeeded: true,
        summary: "Sign in to Epic. Windoz is meant to fetch chunks itself; some titles need the official Epic launcher in Wine.")

    @Published var authState: StoreAuthState = .signedOut
    @Published var games: [StoreGame] = []

    private let credentialAccount = "epic.refreshToken"

    init() {
        if Keychain.has(account: credentialAccount) {
            authState = .signedIn(account: "Stored Epic session")
        }
    }

    func signIn() async {
        authState = .signingIn("Starting Epic sign-in…")
        authState = .error("Native Epic sign-in is not in this build yet. It is being written from the Legendary/Heroic approach.")
    }

    func signOut() {
        Keychain.remove(account: credentialAccount)
        authState = .signedOut
        games = []
    }

    func refreshLibrary() async throws -> [StoreGame] {
        guard authState.isSignedIn else { throw StoreError.notSignedIn }
        throw StoreError.notImplemented("The native Epic library client is not implemented yet.")
    }

    func install(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Native Epic chunked downloads are not implemented yet.")
    }
    func update(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Native Epic updates are not implemented yet.")
    }
    func verify(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Native Epic verification is not implemented yet.")
    }
    func uninstall(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Native Epic removal is not implemented yet.")
    }

    func launchConfiguration(for game: StoreGame) -> GameSettings { .default }
}

// MARK: - GOG

/// GOG is DRM-free, so the best path is simply installing the game's files and
/// adding them as a local game. Galaxy (the client) is optional.
final class GOGStore: ObservableObject, StoreProvider {
    let id: StoreID = .gog

    let capability = StoreCapability(
        signIn: .none,
        downloads: .none,
        library: true,
        updateAndVerify: false,
        cloudSaves: false,
        runtimeLauncherNeeded: false,
        summary: "GOG games are DRM-free: import their installed files directly. No account or client needed.")

    @Published var authState: StoreAuthState = .signedOut
    @Published var games: [StoreGame] = []

    func signIn() async {}
    func signOut() {}
    func refreshLibrary() async throws -> [StoreGame] { games }
    func install(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Install GOG games with a locally-imported folder.")
    }
    func update(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("GOG updates are managed outside Windoz.")
    }
    func verify(_ game: StoreGame) async throws {}
    func uninstall(_ game: StoreGame) async throws {}
    func launchConfiguration(for game: StoreGame) -> GameSettings { .default }
}

// MARK: - Launcher-in-Wine stores (Rockstar, EA)

/// For stores with no usable public API (Rockstar Social Club, the EA app),
/// Windoz runs the vendor's own launcher inside an isolated Wine prefix. The
/// native UI only starts the game through it. Sign-in lives in that prefix and
/// is kept persistent; the launcher is started on demand and closed after the
/// game exits so it never sits in the background.
final class LauncherInWineStore: ObservableObject, StoreProvider {
    let id: StoreID
    let launcherName: String
    /// Official installer URL, or nil when it must be supplied by the user
    /// (Windoz never bundles or redistributes the vendor's client).
    let installerURL: URL?

    let capability: StoreCapability
    @Published var authState: StoreAuthState = .signedOut
    @Published var games: [StoreGame] = []

    /// Each launcher gets its own prefix so sign-in stays isolated and persistent.
    var prefixPath: String { PrefixManager().url.appendingPathComponent("drive_c/\(id.rawValue)-launcher").path }

    init(id: StoreID, launcherName: String, installerURL: URL?) {
        self.id = id
        self.launcherName = launcherName
        self.installerURL = installerURL
        self.capability = StoreCapability(
            signIn: .externalApp,
            downloads: .launcher,
            library: true,
            updateAndVerify: true,
            cloudSaves: true,
            runtimeLauncherNeeded: true,
            summary: "\(launcherName) has no usable public API, so Windoz is meant to run the official launcher inside Wine. You sign in there; the native UI just starts your games through it. That needs the game-session host, which is not ported yet.")
    }

    func signIn() async {
        authState = .signingIn("Starting \(launcherName)…")
        authState = .error("Launching \(launcherName) needs the game-session host, which is the remaining engine port. The launcher's installer is staged once Wi-Fi downloads are enabled.")
    }

    func signOut() {
        authState = .signedOut
        games = []
    }

    func refreshLibrary() async throws -> [StoreGame] {
        throw StoreError.notImplemented("\(launcherName) exposes no public library API; its games come from what you install inside it.")
    }

    func install(_ game: StoreGame) async throws {
        guard let installerURL else {
            throw StoreError.notImplemented("No official installer URL is configured for \(launcherName). Install it on your PC and copy the files, or add the URL in Settings.")
        }
        _ = DownloadManager.shared.enqueue(title: "\(launcherName) installer",
                                           url: installerURL,
                                           destination: URL(fileURLWithPath: prefixPath).appendingPathComponent("launcher-setup.exe"),
                                           storeID: id.rawValue)
        throw StoreError.notImplemented("\(launcherName) setup was queued. Running the installer needs the game-session host, which is the remaining engine port.")
    }

    func update(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Updates happen inside \(launcherName) itself.")
    }
    func verify(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("\(launcherName) verifies its own files.")
    }
    func uninstall(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Uninstall \(launcherName) games from within \(launcherName).")
    }

    func launchConfiguration(for game: StoreGame) -> GameSettings {
        // The launcher requirement is expressed by the capability
        // (`runtimeLauncherNeeded`), which the session host honours. No
        // environment variable is invented for it.
        GameSettings.default
    }
}
