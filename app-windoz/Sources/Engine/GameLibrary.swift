import Foundation

/// The local library: the apps the user can launch, their per-game settings and
/// their playtime. Persisted as JSON at the write-tested storage root
/// (Documents when it accepts writes) with a Keychain mirror for devices whose
/// container refuses files — games themselves are not secret; credentials live
/// in the Keychain.
///
/// A `StoreProvider` materialises its games into this store, so the rest of the
/// app never needs to know which store a game came from.
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published private(set) var games: [InstalledGame] = []

    private let queue = DispatchQueue(label: "windoz.library")

    init() {
        load()
    }

    // MARK: - Queries

    var continuePlaying: [InstalledGame] {
        games.filter { $0.lastPlayedAt != nil }
             .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
             .prefix(6).map { $0 }
    }

    var recentlyAdded: [InstalledGame] {
        games.sorted { $0.addedAt > $1.addedAt }.prefix(10).map { $0 }
    }

    func game(withID id: UUID) -> InstalledGame? { games.first { $0.id == id } }

    // MARK: - Mutations

    func add(_ game: InstalledGame) {
        if let index = games.firstIndex(where: { $0.storeID == game.storeID && $0.storeItemID == game.storeItemID && game.storeItemID != nil }) {
            games[index] = game
        } else {
            games.append(game)
        }
        persist()
    }

    func update(_ game: InstalledGame) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index] = game
        persist()
    }

    func remove(id: UUID) {
        games.removeAll { $0.id == id }
        persist()
    }

    /// Record that a session started for this game.
    func markPlayed(id: UUID, at date: Date = Date()) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].lastPlayedAt = date
        persist()
    }

    /// Add to a game's accumulated playtime.
    func addPlaytime(id: UUID, seconds: Double) {
        guard seconds > 1, let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].playtimeSeconds += seconds
        persist()
    }

    func setSettings(_ settings: GameSettings, for id: UUID) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].settings = settings
        persist()
    }

    func setAntiCheat(_ info: AntiCheatInfo?, for id: UUID) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].antiCheat = info
        persist()
    }

    /// Fill in cover art for an entry that has none — the retro-fetch for
    /// installs made while this device's storage refused writes (0.3.x), so
    /// the shelf shows real covers after the storage repair.
    func updateArtwork(id: UUID, coverPath: String?, heroPath: String?) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if let coverPath, games[index].coverArtPath != coverPath { games[index].coverArtPath = coverPath; changed = true }
        if let heroPath, games[index].heroArtPath != heroPath { games[index].heroArtPath = heroPath; changed = true }
        if changed { persist() }
    }

    // MARK: - Persistence

    /// The Keychain mirror — the one store this device has proven writable
    /// when the container refuses files (Steam and Epic sessions survive
    /// there). A library index is a few KB; anything over the cap is skipped
    /// rather than failing.
    private static let mirrorAccount = "windoz.library.mirror"
    private static let mirrorByteCap = 60_000

    private struct Mirror: Codable {
        var savedAt: Date
        var games: [InstalledGame]
    }

    /// The index can live at the resolved storage root, at the legacy
    /// Documents path, and in the Keychain mirror; the newest readable copy
    /// wins. A file that fails to decode is copied aside and left in place —
    /// never silently replaced with an empty list.
    private func load() {
        let primary = AppContainer.libraryFilePrimary
        let legacy = AppContainer.libraryFile

        struct Copy { var games: [InstalledGame]; var date: Date; var source: String }
        var copies: [Copy] = []

        func consider(_ url: URL, source: String) {
            guard let data = try? Data(contentsOf: url) else { return }
            do {
                let decoded = try JSONDecoder().decode([InstalledGame].self, from: data)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                copies.append(Copy(games: decoded, date: date, source: source))
            } catch {
                EngineLogStream.shared.append(
                    "[library] the \(source) could not be read (\(error.localizedDescription)) — it is kept in place and a copy is set aside",
                    level: .warning)
                let backup = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                if ContainerFS.writeFile(backup.path, data).ok {
                    EngineLogStream.shared.append("[library] unreadable index copied to \(backup.lastPathComponent)")
                }
            }
        }
        consider(primary, source: "storage-root index")
        if legacy.standardizedFileURL.path != primary.standardizedFileURL.path {
            consider(legacy, source: "Documents index")
        }
        if let data = Keychain.get(account: Self.mirrorAccount),
           let mirror = try? JSONDecoder().decode(Mirror.self, from: data) {
            copies.append(Copy(games: mirror.games, date: mirror.savedAt, source: "Keychain mirror"))
        }

        guard let best = copies.max(by: { $0.date < $1.date }) else {
            EngineLogStream.shared.append("[library] no readable index yet (first run, or every copy was refused)")
            return
        }
        games = best.games
        EngineLogStream.shared.append(
            "[library] loaded \(games.count) game\(games.count == 1 ? "" : "s") from the \(best.source)")
    }

    /// Persist to the primary index and the legacy path (each verified), then
    /// refresh the Keychain mirror. Every refusal is logged with its raw
    /// error — a save that did not happen is never silent again.
    private func persist() {
        let snapshot = games
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let primary = AppContainer.libraryFilePrimary
            let legacy = AppContainer.libraryFile

            let primaryOK = Self.writeIndex(data, to: primary, label: "storage root")
            let legacyOK = legacy.standardizedFileURL.path == primary.standardizedFileURL.path
                ? primaryOK
                : Self.writeIndex(data, to: legacy, label: "Documents")
            if !primaryOK && legacyOK {
                EngineLogStream.shared.append(
                    "[library] saved to Documents because the resolved storage root refused", level: .warning)
            }

            var mirrored = false
            if data.count <= Self.mirrorByteCap,
               let mirrorData = try? JSONEncoder().encode(Mirror(savedAt: Date(), games: snapshot)) {
                mirrored = Keychain.set(mirrorData, account: Self.mirrorAccount)
            }
            if !primaryOK && !legacyOK && !mirrored {
                EngineLogStream.shared.append(
                    "[library] the index could not be saved anywhere — it lives in memory until the container is repaired",
                    level: .error)
            }
        }
    }

    private static func writeIndex(_ data: Data, to url: URL, label: String) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            let raw = error as NSError
            if ContainerFS.writeFile(url.path, data).ok {
                EngineLogStream.shared.append(
                    "[library] index saved to \(label) via the C library (Foundation: \(raw.domain) \(raw.code))",
                    level: .warning)
                return true
            }
            EngineLogStream.shared.append(
                "[library] index save refused for \(label): \(raw.domain) \(raw.code) — \(raw.localizedDescription)",
                level: .warning)
            return false
        }
    }
}

extension Double {
    /// "3 h 12 m" style playtime.
    var playtimeDescription: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) m" }
        if minutes > 0 { return "\(minutes) m" }
        return "\(total) s"
    }
}
