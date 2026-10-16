import Foundation

/// The local library: the apps the user can launch, their per-game settings and
/// their playtime. Persisted as JSON in Documents (games themselves are not
/// secret; credentials live in the Keychain).
///
/// A `StoreProvider` materialises its games into this store, so the rest of the
/// app never needs to know which store a game came from.
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published private(set) var games: [InstalledGame] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "windoz.library")

    init(fileURL: URL = AppContainer.libraryFile) {
        self.fileURL = fileURL
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

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([InstalledGame].self, from: data) else { return }
        games = decoded
    }

    private func persist() {
        let snapshot = games
        queue.async { [fileURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
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
