// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — the native Epic Games store.
//
// What is real in this build, verifiable on device:
//  - device-code sign-in: Windoz asks Epic for a code, the owner approves it
//    on epicgames.com/activate, and Epic issues the session to the owner's
//    account (Sources/Epic/EpicAuth.swift). The password never touches the
//    app, and only a refresh token lives in the Keychain;
//  - the owned library: the account's own library-service records, with
//    titles, developers and art from the public catalog
//    (Sources/Epic/EpicAPI.swift).
//
// What is not here yet, and is never claimed: chunked downloads. Epic's
// launcher/CDN endpoints are scoped to the launcher client and refused the
// device-flow session during development, so downloads need a second,
// launcher-scoped authorization (the flow Legendary uses) — that is the next
// piece, and the UI says so instead of pretending.

import Foundation
import Combine
import CryptoKit

@MainActor
final class EpicStore: ObservableObject, StoreProvider {
    let id: StoreID = .epic

    let capability = StoreCapability(
        signIn: .native,
        downloads: .none,
        library: true,
        updateAndVerify: false,
        cloudSaves: false,
        runtimeLauncherNeeded: true,
        summary: "Sign in with Epic's device code — approve it on epicgames.com/activate; Windoz never sees your password. Your owned library is listed with real art. Chunked downloads are the next piece and are not in this build; titles that refuse to start without the official client will run the Epic Games Launcher in Wine.")

    @Published private(set) var authState: StoreAuthState = .signedOut
    @Published private(set) var games: [StoreGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// The last library error, shown in the store sheet.
    @Published var libraryMessage: String?

    /// Driving the sign-in sheet and the library sheet from the UI.
    @Published var showingSignIn = false
    @Published var showingLibrary = false

    private var started = false
    private var observer: NSObjectProtocol?
    private var cachedAccount: String?

    private static var cacheURL: URL {
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
        if let name = EpicSignIn.accountName {
            authState = .signedIn(account: name)
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
        signInChanged()
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
        EpicSignIn.signOut()
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
        do {
            let userToken = try await EpicAuthClient.shared.userToken()
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
            libraryMessage = Self.message(error)
            if let epic = error as? EpicAuthError, epic == .signInExpired {
                // userToken() already removed the stored session; the observer
                // will flip the UI to signed-out.
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

    /// Which account the cached list belongs to: a SHA-256 of the account id,
    /// so the cache file holds no account identifier.
    private static func accountKey(_ accountId: String?) -> String? {
        accountId.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: - Downloads (not in this build — said plainly)

    func install(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Epic chunked downloads are not in this build yet — sign-in and the owned library are. Downloads are the next piece.")
    }

    func update(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Epic updates arrive with the chunk downloader; it is not in this build yet.")
    }

    func verify(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Epic verification arrives with the chunk downloader; it is not in this build yet.")
    }

    func uninstall(_ game: StoreGame) async throws {
        throw StoreError.notImplemented("Nothing is installed through Epic here yet, so there is nothing to remove.")
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
        String(describing: type(of: error))
    }
}
