// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — the native Epic Games store.
//
// What is real in this build, verifiable on device:
//  - device-code sign-in: Windoz asks Epic for a code, the owner approves it
//    on epicgames.com/activate, and Epic issues the session to the owner's
//    account (Sources/Epic/EpicAuth.swift). The password never touches the
//    app, and only a refresh token lives in the Keychain;
//  - the launcher-scoped sign-in: Epic's library service is scoped to the
//    launcher client, so a second, web-based authorization (the code flow
//    Legendary uses) runs in a cookie-less WKWebView, and the library calls
//    prefer that session (Sources/Epic/EpicLauncherAuth.swift);
//  - the owned library: the account's own library-service records, with
//    titles, developers and art from the public catalog
//    (Sources/Epic/EpicAPI.swift);
//  - chunked downloads (0.4.0): the live Windows build's binary manifest and
//    its chunks come from Epic's own CDN; every chunk is verified against the
//    SHA-1 the manifest carries before it is written, files are assembled at
//    their own offsets, and the install registers in the library with art
//    (Sources/Epic/EpicDownloader.swift, ported from Legendary — GPL-3.0).
//
// What is not here yet, and is never claimed: updates, repair and resume.
// Encrypted manifests/chunks are refused with a named reason — that is Epic's
// content protection, and Windoz does not touch it.

import Foundation
import Combine
import CryptoKit

@MainActor
final class EpicStore: ObservableObject, StoreProvider {
    let id: StoreID = .epic

    let capability = StoreCapability(
        signIn: .native,
        downloads: .native,
        library: true,
        updateAndVerify: false,
        cloudSaves: false,
        runtimeLauncherNeeded: true,
        summary: "Sign in with Epic's device code — approve it on epicgames.com/activate; Windoz never sees your password. The owned library needs the launcher-scoped sign-in (the button in this sheet): Epic scopes its library service to the launcher client. Downloads fetch the live Windows build from Epic's own CDN, chunk by chunk, verifying every chunk's hash; updates and repairs come later.")

    @Published private(set) var authState: StoreAuthState = .signedOut
    @Published private(set) var games: [StoreGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// The last library error, shown in the store sheet.
    @Published var libraryMessage: String?

    /// The running download, when one is. The sheet and the store card show
    /// its phase, bytes and detail — never a silent spinner.
    @Published private(set) var download: DownloadState?

    struct DownloadState: Equatable {
        var gameID: String
        var phase: String
        var doneBytes: UInt64
        var totalBytes: UInt64
        var detail: String

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(doneBytes) / Double(totalBytes))
        }
    }

    /// Driving the sign-in sheet and the library sheet from the UI.
    @Published var showingSignIn = false
    @Published var showingLibrary = false
    /// Whether the launcher-scoped session (the library's scope) is stored.
    @Published private(set) var launcherSignedIn = false

    private var started = false
    private var observer: NSObjectProtocol?
    private var launcherObserver: NSObjectProtocol?
    private var cachedAccount: String?

    private static var cacheURL: URL {
        AppContainer.storageRoot.appendingPathComponent("windoz-epic-library.json")
    }

    /// The 0.3.x location, read as a fallback so an upgrade keeps the cache.
    private static var legacyCacheURL: URL {
        AppContainer.documents.appendingPathComponent("windoz-epic-library.json")
    }

    private struct Cache: Codable {
        var version: Int
        var updated: Date
        var account: String
        var games: [StoreGame]
    }

    // MARK: - Lifecycle

    init() {
        BootTrace.mark("EpicStore.init enter")
        launcherSignedIn = EpicLauncherSignIn.isSignedIn
        if let name = EpicSignIn.accountName {
            BootTrace.mark("EpicStore.init signed in")
            authState = .signedIn(account: name)
        } else {
            BootTrace.mark("EpicStore.init signed out")
        }
    }

    /// Called once when the store is first used (StoreRegistry). Observes
    /// sign-in changes; reads the cached library; refreshes it when stale.
    func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(
            forName: EpicSignIn.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.signInChanged() }
        }
        launcherObserver = NotificationCenter.default.addObserver(
            forName: EpicLauncherSignIn.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.launcherSignInChanged() }
        }
        signInChanged()
        launcherSignInChanged()
    }

    private func launcherSignInChanged() {
        launcherSignedIn = EpicLauncherSignIn.isSignedIn
        EpicLog.event("[epic-launcher] store state signed-in=\(launcherSignedIn ? 1 : 0)")
        if launcherSignedIn, authState.isSignedIn {
            // The library calls now have the client scope Epic wants them
            // with — refresh right away.
            Task { await refreshIfPossible(interactive: true) }
        }
    }

    private func signInChanged() {
        if let name = EpicSignIn.accountName {
            authState = .signedIn(account: name)
            loadCache()
            if Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
                Task { await refreshIfPossible(interactive: false) }
            }
        } else {
            authState = .signedOut
            games = []
            libraryUpdated = nil
            cachedAccount = nil
            libraryMessage = nil
            try? FileManager.default.removeItem(at: Self.cacheURL)
        }
        EpicLog.event("[epic-library] state signed-in=\(authState.isSignedIn ? 1 : 0) games=\(games.count)")
    }

    // MARK: - Sign-in (StoreProvider)

    func signIn() async {
        showingSignIn = true
    }

    func signOut() {
        // Both sessions belong to the same account: signing out means both.
        EpicSignIn.signOut()
        EpicLauncherSignIn.signOut()
    }

    // MARK: - Library (StoreProvider)

    /// `interactive = true` (the Refresh button) surfaces failures; the
    /// automatic refresh only logs transient ones.
    private func refreshIfPossible(interactive: Bool) async {
        do {
            _ = try await refreshLibrary()
        } catch {
            if interactive { libraryMessage = Self.message(error) }
            EpicLog.event("[epic-library] refresh failed interactive=\(interactive ? 1 : 0) reason=\(Self.reason(error))")
        }
    }

    @discardableResult
    func refreshLibrary() async throws -> [StoreGame] {
        guard authState.isSignedIn else { throw StoreError.notSignedIn }
        guard !refreshing else { return games }
        refreshing = true
        defer { refreshing = false }
        // The library service is scoped to the launcher client, so the
        // launcher session is preferred when it exists; the device-flow
        // session is tried next (it works for the account endpoints and the
        // catch below names the scope problem when the library refuses it).
        let usedLauncher = EpicLauncherSignIn.isSignedIn
        do {
            let userToken = usedLauncher
                ? try await EpicLauncherAuthClient.shared.userToken()
                : try await EpicAuthClient.shared.userToken()
            let items = try await EpicAPI.libraryItems(userToken: userToken)
            let catalog = await Self.fetchCatalog(for: items)
            var seen = Set<String>()
            let mapped: [StoreGame] = items.compactMap { item in
                let key = "\(item.namespace):\(item.catalogItemId)"
                guard seen.insert(key).inserted else { return nil }
                let meta = catalog[key]
                if let meta, !EpicAPI.looksInstallable(meta) { return nil }
                return StoreGame(
                    id: key,
                    storeID: .epic,
                    title: meta?.title ?? item.appName ?? item.catalogItemId,
                    subtitle: meta?.developer,
                    coverURL: meta.flatMap(EpicAPI.coverURL),
                    heroURL: meta.flatMap(EpicAPI.heroURL),
                    sizeBytes: nil,
                    installed: false,
                    needsRuntimeLauncher: true,
                    antiCheat: nil,
                    compatibility: .unknown)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

            games = mapped
            libraryUpdated = Date()
            libraryMessage = nil
            cachedAccount = Self.accountKey(EpicSignIn.storedSession()?.accountId)
            writeCache()
            EpicLog.event("[epic-library] items=\(items.count) shown=\(mapped.count)")
            return mapped
        } catch {
            // A refused library call from the device session has a known fix,
            // and the sheet must say it instead of a bare status.
            if !usedLauncher, let epic = error as? EpicAuthError,
               case .http(let status, _) = epic, status == 403 || status == 401 {
                libraryMessage = "Epic refused the library call for the device-code session (HTTP \(status)) — the library service is scoped to the launcher client. Use “Epic launcher sign-in” in this sheet, then refresh."
            } else {
                libraryMessage = Self.message(error)
            }
            if let epic = error as? EpicAuthError, epic == .signInExpired {
                // Only a refused refresh grant lands here — `userToken()`
                // cleared the stored session. A service refusing one call
                // (e.g. HTTP 403 from an endpoint scoped to another client)
                // keeps the session; the sheet shows the status instead of
                // silently signing the owner out.
                authState = .signedOut
            }
            throw error
        }
    }

    /// Catalog metadata for the library items, bounded to six in flight.
    /// Failures are per item: a title falls back to the app name.
    private static func fetchCatalog(for items: [EpicAPI.LibraryItem]) async -> [String: EpicAPI.CatalogItem] {
        guard let clientToken = try? await EpicAuthClient.shared.clientCredentials() else { return [:] }
        var catalog: [String: EpicAPI.CatalogItem] = [:]
        let wanted = Array(items.prefix(400))
        var index = 0
        while index < wanted.count {
            let batch = Array(wanted[index..<min(index + 6, wanted.count)])
            index += 6
            let results = await withTaskGroup(of: (String, EpicAPI.CatalogItem?).self) { group -> [(String, EpicAPI.CatalogItem?)] in
                for item in batch {
                    group.addTask {
                        let key = "\(item.namespace):\(item.catalogItemId)"
                        let meta = try? await EpicAPI.catalogItem(
                            namespace: item.namespace,
                            catalogItemId: item.catalogItemId,
                            clientToken: clientToken)
                        return (key, meta)
                    }
                }
                var out: [(String, EpicAPI.CatalogItem?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (key, meta) in results {
                if let meta { catalog[key] = meta }
            }
        }
        return catalog
    }

    // MARK: - Cache

    private func loadCache() {
        let account = Self.accountKey(EpicSignIn.storedSession()?.accountId)
        cachedAccount = account
        var data = try? Data(contentsOf: Self.cacheURL)
        if data == nil, Self.legacyCacheURL != Self.cacheURL {
            data = try? Data(contentsOf: Self.legacyCacheURL)
        }
        guard let data, data.count <= 64 << 20,
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

    /// Which account the cached list belongs to: a SHA-256 of the account id,
    /// so the cache file holds no account identifier.
    private static func accountKey(_ accountId: String?) -> String? {
        accountId.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: - Downloads

    /// Epic's chunked install. The live Windows build's manifest is fetched
    /// with the launcher-scoped session, every chunk is verified against the
    /// SHA-1 the manifest carries, and the files land in
    /// <storage root>/EpicGames/<title>. Every step is logged; every refusal
    /// is a sentence.
    func install(_ game: StoreGame) async throws {
        guard authState.isSignedIn else { throw StoreError.notSignedIn }
        guard download == nil else {
            throw StoreError.notImplemented("An Epic download is already running — let it finish first.")
        }
        let identifiers = game.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard identifiers.count == 2, !identifiers[0].isEmpty, !identifiers[1].isEmpty else {
            throw StoreError.notImplemented("This entry is missing its Epic identifiers; refresh the library and try again.")
        }
        let namespace = identifiers[0], catalogItemId = identifiers[1]

        download = DownloadState(gameID: game.id, phase: "Preparing", doneBytes: 0, totalBytes: 0,
                                 detail: "Asking Epic for the live build")
        defer { download = nil }

        do {
            let token = try await downloadToken()
            let appName = await resolveAppName(namespace: namespace, catalogItemId: catalogItemId, token: token)
            guard let manifestURL = try await EpicAPI.assetManifestURL(namespace: namespace,
                                                                       catalogItemId: catalogItemId,
                                                                       appName: appName, userToken: token) else {
                throw StoreError.notImplemented("Epic has no live Windows build for this title. It may not be released for Windows yet.")
            }
            EpicLog.event("[epic-download] start app=\(appName ?? catalogItemId)")

            let result = try await EpicDownloader.install(
                manifestURL: manifestURL, bearerToken: token,
                folderName: EpicDownloader.folderName(for: game.title)) { progress in
                await self.publish(progress, for: game.id)
            }
            EpicLog.event("[epic-download] done files=\(result.fileCount) bytes=\(result.bytes) "
                          + "exe=\(result.executablePath == nil ? 0 : 1) skipped-symlinks=\(result.skippedSymlinks)")

            // Art and registration are best-effort after a completed
            // download: a title that arrived must land in the library even if
            // the art CDN fails.
            let art = await fetchArt(for: game)
            registerInstalled(game: game, result: result, art: art)
        } catch {
            EpicLog.event("[epic-download] failed app=\(game.title) reason=\(Self.reason(error))")
            throw error
        }
    }

    private func publish(_ progress: EpicDownloader.Progress, for gameID: String) {
        var state = download ?? DownloadState(gameID: gameID, phase: progress.phase.rawValue,
                                              doneBytes: 0, totalBytes: 0, detail: "")
        state.gameID = gameID
        state.phase = progress.phase.rawValue
        state.doneBytes = progress.doneBytes
        state.totalBytes = progress.totalBytes
        state.detail = progress.detail
        download = state
    }

    /// The launcher session first (the assets service is launcher-scoped),
    /// then the device session, then the client credentials.
    private func downloadToken() async throws -> String {
        if EpicLauncherSignIn.isSignedIn,
           let token = try? await EpicLauncherAuthClient.shared.userToken(), !token.isEmpty {
            return token
        }
        if let token = try? await EpicAuthClient.shared.userToken(), !token.isEmpty {
            return token
        }
        return try await EpicAuthClient.shared.clientCredentials()
    }

    /// The app name Epic's assets service wants, from the owner's own library
    /// items. Nil is fine — the v1 list fallback matches by catalog item.
    private func resolveAppName(namespace: String, catalogItemId: String, token: String) async -> String? {
        guard let items = try? await EpicAPI.libraryItems(userToken: token) else { return nil }
        return items.first { $0.namespace == namespace && $0.catalogItemId == catalogItemId }?.appName
    }

    private func registerInstalled(game: StoreGame, result: EpicDownloader.Result,
                                   art: (cover: String?, hero: String?)) {
        var installed = InstalledGame(
            title: game.title,
            executablePath: result.executablePath ?? "",
            workingDirectory: result.folder.path,
            coverArtPath: art.cover,
            heroArtPath: art.hero,
            storeID: StoreID.epic.rawValue,
            storeItemID: game.id)
        let antiCheat = AntiCheatDetector.detect(inFolder: result.folder.path)
        installed.antiCheat = antiCheat
        installed.compatibility = antiCheat?.onlineRisk == .unsupported ? .unsupported : .playable
        GameLibrary.shared.add(installed)

        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].installed = true
            if result.bytes > 0 { games[index].sizeBytes = Int64(clamping: result.bytes) }
        }
        writeCache()
        if result.skippedSymlinks > 0 {
            libraryMessage = "Installed, but \(result.skippedSymlinks) manifest entries that are links were skipped — the game may miss some files."
        } else if result.executablePath == nil {
            libraryMessage = "Installed, but the game's program could not be identified from Epic's manifest. Open the game's page to point Windoz at its .exe."
        }
    }

    private func fetchArt(for game: StoreGame) async -> (cover: String?, hero: String?) {
        async let cover = fetchArtFile(game.coverURL, name: artName(game, "cover"))
        async let hero = fetchArtFile(game.heroURL, name: artName(game, "hero"))
        return await (cover, hero)
    }

    private func artName(_ game: StoreGame, _ kind: String) -> String {
        let digest = SHA256.hash(data: Data(game.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return "epic-\(digest.prefix(12))-\(kind).jpg"
    }

    private func fetchArtFile(_ url: URL?, name: String) async -> String? {
        guard let url else { return nil }
        let destination = AppContainer.artDirectory.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path),
           let existing = try? Data(contentsOf: destination), !existing.isEmpty {
            return destination.path
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            EpicLog.event("[epic-art] fetch failed \(name)")
            return nil
        }
        do {
            try data.write(to: destination, options: .atomic)
            return destination.path
        } catch {
            if ContainerFS.writeFile(destination.path, data).ok { return destination.path }
            EpicLog.event("[epic-art] could not save \(name): \(error.localizedDescription)")
            return nil
        }
    }

    func update(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Epic updates will re-check an installed build against Epic's live manifest; not in this build yet. Downloading the game again updates it.")
    }

    func verify(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Epic verification — comparing installed files against the live manifest — is not in this build yet.")
    }

    func uninstall(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Removing an Epic install from Windoz is not in this build yet; the game's files live in Windoz's storage under EpicGames/.")
    }

    // MARK: - Launch configuration (StoreProvider)

    /// Engine switches are Windoz's own settings; the launcher requirement is
    /// expressed by `StoreCapability.runtimeLauncherNeeded` and honoured by
    /// the session host, not by an invented environment variable.
    func launchConfiguration(for game: StoreGame) -> GameSettings {
        GameSettings.default
    }

    // MARK: - Messages

    static func message(_ error: Error) -> String {
        if let epic = error as? EpicAuthError { return epic.errorDescription ?? "Epic sign-in failed." }
        if let store = error as? StoreError { return store.errorDescription ?? "The store could not be reached." }
        return error.localizedDescription
    }

    static func reason(_ error: Error) -> String {
        if let epic = error as? EpicAuthError, case .http(let status, _) = epic {
            return "http \(status)"
        }
        return String(describing: type(of: error))
    }
}
