// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — the native Steam store.
//
// The Steam client (sign-in, the account's owned library and the depot
// downloader) is the SwiftSteam port from Madeira (GPL-3.0-or-later + Madeira
// Converter Exception, see Sources/Steam/). This file is the Windoz side: it
// wires that client to Windoz's `StoreProvider` protocol, the app's Keychain
// sign-in, the game library and the UI.
//
// What is real today, verifiable on device:
//  - sign-in with password + Steam Guard (code or in-app approval) or a QR
//    code scanned by the Steam app (Sources/Steam/SteamSignIn.swift);
//  - the owned library, from the account's own licenses over Steam's CM
//    protocol (SteamLibraryFetcher);
//  - depot downloads, decryption and decompression into the Windows prefix's
//    `Program Files (x86)\Steam\steamapps` in the exact layout Steam's own
//    client writes (DepotDownloader + SteamInstall/AppManifestWriter);
//  - re-verification: every already-downloaded chunk is checked against
//    Steam's SHA-1 before it is skipped, so Install doubles as Verify, and
//    resumes from the on-disk journals.
//
// What is not here yet, and is never claimed: starting the games. Steam-DRM
// titles need Valve's own client (or an equivalent) running in the prefix,
// which arrives with the game-session host (see StoreCapability.summary).

import Foundation
import Combine
import CryptoKit

@MainActor
final class SteamStore: ObservableObject, StoreProvider {
    let id: StoreID = .steam

    let capability = StoreCapability(
        signIn: .native,
        downloads: .native,
        library: true,
        updateAndVerify: true,
        cloudSaves: false,
        runtimeLauncherNeeded: true,
        summary: "Sign in to Steam directly (password + Steam Guard, or a QR code). Windoz downloads your owned depots itself into the prefix's Steam library and verifies or repairs them on request. Starting Steam games needs Valve's client in the prefix, which arrives with the game-session host.")

    @Published private(set) var authState: StoreAuthState = .signedOut
    @Published private(set) var games: [StoreGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// The last library/download error, shown in the store sheet.
    @Published var libraryMessage: String?

    /// Driving the sign-in sheet and the library sheet from the UI.
    @Published var showingSignIn = false
    @Published var showingLibrary = false

    // MARK: - Downloads

    struct Download: Equatable {
        enum State: Equatable {
            case queued
            case active
            case failed(String)
        }
        var state: State = .queued
        var progress = SteamDownloadProgress()
        var title = ""
        /// Finished chunks are journaled on disk: install again to resume.
        var resumable = false
        var isActive: Bool { state == .active }
    }

    @Published private(set) var downloads: [UInt32: Download] = [:]

    private let session = SteamSession()
    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private var queue: [UInt32] = []
    private var active: (id: UInt32, task: Task<Void, Never>)?
    private var started = false
    private var signInObserver: NSObjectProtocol?

    // MARK: - Paths (the same layout Steam's own client writes)

    static var prefix: PrefixManager { PrefixManager() }
    /// `C:\Program Files (x86)\Steam\steamapps`, on the host side.
    static var steamApps: URL {
        prefix.url.appendingPathComponent("drive_c/\(SteamInstallPaths.libraryRelative)", isDirectory: true)
    }

    private static var cacheURL: URL {
        AppContainer.documents.appendingPathComponent("windoz-steam-library.json")
    }

    private struct Cache: Codable {
        var version: Int
        var updated: Date
        var account: String
        var games: [StoreGame]
    }

    /// Which account the cached list belongs to: a SHA-256 of the account name,
    /// so the cache file holds no name.
    private var cachedAccount: String?
    private static func accountKey(_ name: String?) -> String? {
        name.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: - Lifecycle

    init() {
        BootTrace.mark("SteamStore.init enter")
        if let account = SteamSignIn.accountName {
            BootTrace.mark("SteamStore.init signed in")
            authState = .signedIn(account: account)
        } else {
            BootTrace.mark("SteamStore.init signed out")
        }
    }

    /// Called once when the store is first used (StoreRegistry). Observes
    /// sign-in changes; reads the cached library; refreshes it when stale.
    func start() {
        guard !started else { return }
        started = true
        signInObserver = NotificationCenter.default.addObserver(
            forName: SteamSignIn.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.signInChanged() }
        }
        signInChanged()
    }

    private func signInChanged() {
        if let account = SteamSignIn.accountName {
            authState = .signedIn(account: account)
            loadCache()
            if Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
                Task { await refreshIfPossible(interactive: false) }
            }
        } else {
            let wasSignedIn = authState.isSignedIn
            authState = .signedOut
            if wasSignedIn { session.logoff() }
            games = []
            libraryUpdated = nil
            cachedAccount = nil
            libraryMessage = nil
            downloads = [:]
            queue.removeAll()
            active?.task.cancel()
            try? FileManager.default.removeItem(at: Self.cacheURL)
        }
        SteamLog.event("[steam-library] state signed-in=\(authState.isSignedIn ? 1 : 0) games=\(games.count)")
    }

    // MARK: - Sign-in (StoreProvider)

    func signIn() async {
        guard SteamSignIn.isEnabled else { return }
        showingSignIn = true
    }

    func signOut() {
        SteamSignIn.signOut()
    }

    // MARK: - Library (StoreProvider)

    /// `interactive = true` (the Refresh button, sign-in) surfaces failures;
    /// the automatic refresh only logs transient ones.
    private func refreshIfPossible(interactive: Bool) async {
        do {
            _ = try await refreshLibrary()
        } catch {
            if interactive { libraryMessage = SteamSignIn.message(error) }
            SteamLog.event("[steam-library] refresh failed interactive=\(interactive ? 1 : 0) reason=\(SteamSignIn.reason(error))")
        }
    }

    @discardableResult
    func refreshLibrary() async throws -> [StoreGame] {
        guard authState.isSignedIn else { throw StoreError.notSignedIn }
        guard !refreshing else { return games }
        refreshing = true
        defer { refreshing = false }
        do {
            let apps = try await fetcher.fetchOwnedApps()
            let mapped = apps
                .filter(\.installableOnWindows)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map(Self.storeGame)
            games = mapped
            libraryUpdated = Date()
            libraryMessage = nil
            cachedAccount = Self.accountKey(SteamSignIn.accountName)
            writeCache()
            SteamLog.event("[steam-library] owned apps=\(apps.count) windows-installable=\(mapped.count)")
            return mapped
        } catch {
            handleSessionError(error)
            throw error
        }
    }

    /// A rejected stored token is said plainly and the sheet offers sign-out.
    private func handleSessionError(_ error: Error) {
        if case SteamError.logonDenied(let code) = error, SteamError.signInExpiredCodes.contains(code) {
            libraryMessage = "Your Steam sign-in is no longer valid. Sign out and sign in again."
            SteamLog.event("[steam-account] stored sign-in rejected code=\(code)")
        } else {
            libraryMessage = SteamSignIn.message(error)
        }
    }

    // MARK: - Cache

    private func loadCache() {
        let account = Self.accountKey(SteamSignIn.accountName)
        cachedAccount = account
        guard let data = try? Data(contentsOf: Self.cacheURL), data.count <= 64 << 20,
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == 1, cache.account == account else { return }
        games = cache.games
        libraryUpdated = cache.updated
    }

    private func writeCache() {
        guard let account = cachedAccount, let updated = libraryUpdated else { return }
        let cache = Cache(version: 1, updated: updated, account: account, games: games)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: - StoreGame mapping

    static func storeGame(_ info: SteamAppInfo) -> StoreGame {
        let appID = Int(info.appID)
        let folder = SteamInstallFiles.safeFolderName(info.installDir.isEmpty ? "app_\(appID)" : info.installDir)
        let installed = SteamInstallFiles.buildID(appID: appID, steamApps: steamApps) != nil || installedMarker(appID: info.appID, folderName: folder)
        let size = info.installDepots().reduce(UInt64(0)) { $0 &+ $1.publicSizeBytes }
        return StoreGame(
            id: "\(appID)",
            storeID: .steam,
            title: info.name.isEmpty ? "App \(appID)" : info.name,
            subtitle: info.installDir.isEmpty ? nil : "Steam · \(info.installDir)",
            coverURL: coverURL(info),
            heroURL: heroURL(info),
            sizeBytes: size > 0 ? Int64(size) : nil,
            installed: installed,
            needsRuntimeLauncher: true,
            antiCheat: nil,
            compatibility: .unknown)
    }

    /// A kept observation: the install folder exists even when the manifest is
    /// gone (manual deletion of the record). Only used to avoid claiming
    /// "not installed" for files that are there.
    private static func installedMarker(appID: UInt32, folderName: String) -> Bool {
        let folder = steamApps.appendingPathComponent("common/\(folderName)", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Artwork (Steam's public store CDN; no account data)

    private static let storeAssetBase = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/"

    private static func storeAsset(_ name: String?, appID: Int) -> URL? {
        guard let name, !name.isEmpty, name.utf8.count <= 256, !name.hasPrefix("/"), !name.contains(".."),
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) })
        else { return nil }
        return URL(string: storeAssetBase + "\(appID)/" + name)
    }

    static func coverURL(_ info: SteamAppInfo) -> URL? {
        storeAsset(info.libraryCapsule, appID: Int(info.appID))
            ?? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(info.appID)/library_600x900.jpg")
    }

    static func heroURL(_ info: SteamAppInfo) -> URL? {
        storeAsset(info.libraryHero, appID: Int(info.appID))
            ?? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(info.appID)/library_hero.jpg")
    }

    // MARK: - Downloads (StoreProvider)

    func install(_ game: StoreGame) async throws {
        try enqueue(game)
    }

    /// Update to the current manifests: the downloader skips every chunk whose
    /// SHA-1 the existing file already has, so this pulls only what changed.
    func update(_ game: StoreGame) async throws {
        try enqueue(game)
    }

    /// Verify: every existing file is re-read against Steam's chunk hashes and
    /// anything that does not match is downloaded again. Same code path.
    func verify(_ game: StoreGame) async throws {
        try enqueue(game)
    }

    private func enqueue(_ game: StoreGame) throws {
        guard let appID = UInt32(game.id) else { throw StoreError.network("This game has no Steam app id.") }
        guard authState.isSignedIn else { throw StoreError.notSignedIn }
        guard downloads[appID] == nil else { return }
        downloads[appID] = Download(
            state: .queued,
            title: game.title,
            resumable: DepotDownloader.hasPartialDownload(appID: appID, steamApps: Self.steamApps))
        queue.append(appID)
        pump()
    }

    /// Clears a finished/failed entry so the game can be installed again.
    func retry(_ game: StoreGame) {
        guard let appID = UInt32(game.id) else { return }
        if active?.id != appID { downloads[appID] = nil }
        Task { try? await install(game) }
    }

    func cancelDownload(_ appID: UInt32) {
        if let active, active.id == appID {
            downloads[appID] = Download(
                state: .failed("Download cancelled. Finished parts are kept — Install resumes from them."),
                title: downloads[appID]?.title ?? "",
                resumable: true)
            active.task.cancel()
        } else {
            queue.removeAll { $0 == appID }
            downloads[appID] = nil
        }
    }

    /// Clears a failed entry (dismiss). A running download is not affected.
    func clearDownload(_ appID: UInt32) {
        guard active?.id != appID else { return }
        queue.removeAll { $0 == appID }
        downloads[appID] = nil
    }

    func uninstall(_ game: StoreGame) async throws {
        guard let appID = UInt32(game.id) else { throw StoreError.network("This game has no Steam app id.") }
        cancelDownload(appID)
        let folderName = manifestValue(appID: appID, key: "installdir")
            ?? SteamInstallFiles.safeFolderName(game.title)
        SteamInstallFiles.delete(appID: Int(appID), folderName: folderName, steamApps: Self.steamApps)
        if let entry = GameLibrary.shared.games.first(where: { $0.storeID == StoreID.steam.rawValue && $0.storeItemID == game.id }) {
            GameLibrary.shared.remove(id: entry.id)
        }
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].installed = false
        }
        writeCache()
        SteamLog.event("[steam-library] uninstalled app=\(appID)")
    }

    // MARK: - Download queue (one at a time)

    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        let appID = queue.removeFirst()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(appID)
        }
        active = (appID, task)
    }

    private func run(_ appID: UInt32) async {
        defer {
            active = nil
            pump()
        }
        guard var entry = downloads[appID] else { return }
        let title = entry.title
        entry.state = .active
        downloads[appID] = entry
        do {
            guard let info = try await fetcher.fetchInstallInfo(appID: appID) else {
                throw StoreError.network("Steam did not return install information for this game.")
            }
            let folder = try await downloader.install(
                info,
                steamApps: Self.steamApps,
                ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() }
            ) { [weak self] progress in
                self?.downloads[appID]?.progress = progress
            }
            downloads[appID] = nil
            registerInstalled(info: info, folder: folder)
        } catch is CancellationError {
            downloads[appID] = Download(
                state: .failed("Download cancelled. Finished parts are kept — Install resumes from them."),
                title: title, resumable: true)
        } catch {
            downloads[appID] = Download(
                state: .failed(SteamSignIn.message(error)),
                title: title,
                resumable: DepotDownloader.hasPartialDownload(appID: appID, steamApps: Self.steamApps))
            SteamLog.event("[steam-depot] failed app=\(appID) reason=\(SteamSignIn.reason(error))")
        }
    }

    /// The depot download finished: the game is now a real installed game in
    /// Windoz's library (and in `steamapps` in Valve's own layout).
    private func registerInstalled(info: SteamAppInfo, folder: URL) {
        let appID = "\(info.appID)"
        let installed = Self.installedGame(info: info, folder: folder)
        GameLibrary.shared.add(installed)
        if let index = games.firstIndex(where: { $0.id == appID }) {
            games[index].installed = true
        }
        writeCache()
        SteamLog.event("[steam-depot] installed app=\(info.appID) exe-found=\(installed.executablePath.isEmpty ? 0 : 1)")
    }

    static func installedGame(info: SteamAppInfo, folder: URL) -> InstalledGame {
        let exe = launchExecutable(info: info, folder: folder)
        var game = InstalledGame(
            title: info.name.isEmpty ? "App \(info.appID)" : info.name,
            executablePath: exe ?? "",
            workingDirectory: folder.path,
            coverArtPath: nil,
            heroArtPath: nil,
            storeID: StoreID.steam.rawValue,
            storeItemID: "\(info.appID)")
        let antiCheat = AntiCheatDetector.detect(inFolder: folder.path)
        game.antiCheat = antiCheat
        game.compatibility = antiCheat?.onlineRisk == .unsupported ? .unsupported : .playable
        return game
    }

    // MARK: - The game's program

    /// The Windows entry Steam itself would start: the app's own launch
    /// configuration first (`type == "default"`, Windows or platform-neutral),
    /// then a bounded search for a plausible game executable.
    static func launchExecutable(info: SteamAppInfo, folder: URL) -> String? {
        let fm = FileManager.default
        let candidates = info.launches.filter { $0.oslist.isEmpty || $0.oslist.lowercased().contains("windows") }
        let ordered = candidates.sorted { score($0) < score($1) }
        for option in ordered {
            guard var path = launchPath(option.executable) else { continue }
            path = path.replacingOccurrences(of: "\\", with: "/")
            if let range = path.range(of: ".exe", options: [.caseInsensitive]) {
                path = String(path[..<range.upperBound])
            }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { return url.standardizedFileURL.path }
        }
        return scanForExecutable(in: folder)
    }

    private static func score(_ option: SteamLaunchOption) -> Int {
        if option.type == "default" { return 0 }
        if option.type.isEmpty { return 1 }
        return 2
    }

    /// Steam launch entries can carry quotes and arguments around the path.
    private static func launchPath(_ executable: String) -> String? {
        var text = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("\"") {
            text.removeFirst()
            if let end = text.firstIndex(of: "\"") { text = String(text[..<end]) }
            return text.isEmpty ? nil : text
        }
        return text
    }

    /// A bounded fallback walk: skip redistributables and crash handlers.
    private static func scanForExecutable(in folder: URL) -> String? {
        let fm = FileManager.default
        let skipNames: Set<String> = ["redist", "_commonredist", "directx", "support", "vcredist", "dotnet", "dxsetup", "engine"]
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true })
        else { return nil }
        var found: String?
        var depthGuard = 0
        while let item = enumerator.nextObject() as? URL {
            depthGuard += 1
            if depthGuard > 20_000 { break }
            let name = item.lastPathComponent
            if name.lowercased() == ".ds_store" { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                let components = item.pathComponents.count - folder.pathComponents.count
                if components >= 4 || skipNames.contains(name.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard name.lowercased().hasSuffix(".exe") else { continue }
            let lower = name.lowercased()
            if lower.hasPrefix("unins") || lower.hasPrefix("unitycrashhandler") || lower.contains("vcredist") || lower.contains("dxsetup") {
                continue
            }
            if let previous = found {
                if item.path.count < previous.count { found = item.path }
            } else {
                found = item.path
            }
        }
        return found?.isEmpty == false ? found : nil
    }

    // MARK: - Install record helpers

    /// A value out of `appmanifest_<appid>.acf`'s `AppState`, when it names
    /// this app.
    private func manifestValue(appID: UInt32, key: String) -> String? {
        let url = Self.steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], state["appid"]?.string == String(appID) else { return nil }
        return state[key]?.string
    }

    // MARK: - Launch configuration (StoreProvider)

    /// The engine switches are Windoz's own settings; the Steam-DRM runtime
    /// requirement is expressed by `StoreCapability.runtimeLauncherNeeded` and
    /// honoured by the session host, not by an invented environment variable.
    func launchConfiguration(for game: StoreGame) -> GameSettings {
        GameSettings.default
    }
}
