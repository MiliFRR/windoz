import SwiftUI
import UIKit

/// Home is a normal iPhone shelf now: "Continue playing", "Recently added",
/// and a compact list of the rest. No wordmark, no hero carousel, no glow.
struct HomeView: View {
    @EnvironmentObject private var library: GameLibrary
    @ObservedObject private var controller = ControllerManager.shared
    @StateObject private var focus = ConsoleFocus()
    @State private var selection: InstalledGame?

    private var continueGames: [InstalledGame] { library.continuePlaying }
    private var recentGames: [InstalledGame] { library.recentlyAdded }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if library.games.isEmpty {
                    emptyState
                } else {
                    if let game = continueGames.first {
                        featured(game)
                    }
                    let rest = Array(continueGames.dropFirst())
                    if !rest.isEmpty {
                        shelf(title: "Recently played", games: rest,
                              width: Metrics.shelfTileWidth, height: Metrics.shelfTileHeight)
                    }
                    if !recentGames.isEmpty {
                        shelf(title: "Recently added", games: recentGames,
                              width: Metrics.shelfTileWidth, height: Metrics.shelfTileHeight)
                    }
                    allGames
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 8)
        }
        .background(ConsoleBackground())
        .navigationTitle("Home")
        .navigationDestination(item: $selection) { game in
            GameDetailView(gameID: game.id)
        }
        .onAppear {
            focus.count = continueGames.count
            controller.onButton = handle
        }
        .onDisappear { controller.onButton = nil }
        .onChange(of: continueGames.count) { _, newValue in
            focus.count = newValue
            focus.reset()
        }
    }

    // MARK: - Shelves

    /// The top card: the game played most recently, drawn full-width with its
    /// hero art and one clear play affordance. Tapping opens the game page,
    /// where Play starts the session (and runs its preflight).
    private func featured(_ game: InstalledGame) -> some View {
        Button { open(game) } label: {
            ZStack(alignment: .bottomLeading) {
                HeroArtView(path: game.heroArtPath ?? game.coverArtPath)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.featuredHeight)
                    .clipped()
                LinearGradient(colors: [Color.black.opacity(0.02), Color.black.opacity(0.74)],
                               startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(game.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(featuredSubtitle(game))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "play.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Theme.actionGradient))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.featuredHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
            .overlay {
                if isFocused(game) {
                    RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue playing \(game.title)")
    }

    private func featuredSubtitle(_ game: InstalledGame) -> String {
        var parts: [String] = []
        if let last = game.lastPlayedAt { parts.append("Played \(Self.relativeText(last))") }
        if game.playtimeSeconds > 0 { parts.append(game.playtimeSeconds.playtimeDescription) }
        parts.append(game.compatibility.title)
        return parts.joined(separator: " · ")
    }

    private func shelf(title: String, games: [InstalledGame], width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(games) { game in
                        Button { open(game) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverArtView(title: game.title, imagePath: game.coverArtPath,
                                             corner: Metrics.tileCorner)
                                    .frame(width: width, height: height)
                                    .overlay {
                                        if isFocused(game) {
                                            RoundedRectangle(cornerRadius: Metrics.tileCorner, style: .continuous)
                                                .strokeBorder(Theme.accent, lineWidth: 2)
                                        }
                                    }
                                Text(game.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: width, alignment: .leading)
                                if let last = game.lastPlayedAt {
                                    Text(Self.relativeText(last))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: width, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(game.title), \(game.compatibility.title)")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    /// The rest of the library as a plain list, the way a first-party library
    /// tab draws it. The full grid lives in the Library tab.
    private var allGames: some View {
        let shown = Array(library.games.prefix(8))
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "All games")
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, game in
                    Button { open(game) } label: { row(game) }
                        .buttonStyle(.plain)
                    if index < shown.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
            if library.games.count > shown.count {
                Text("Showing \(shown.count) of \(library.games.count). The Library tab has the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ game: InstalledGame) -> some View {
        HStack(spacing: 12) {
            CoverArtView(title: game.title, imagePath: game.coverArtPath, corner: 6)
                .frame(width: 44, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(game.lastPlayedAt.map { "Played \(Self.relativeText($0))" } ?? "Not played yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No games yet", systemImage: "gamecontroller")
        } description: {
            Text("Import a game from Files, or connect a store in the Library tab. DRM-free games run best.")
        }
        .padding(.top, 40)
    }

    // MARK: - Helpers

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeText(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func isFocused(_ game: InstalledGame) -> Bool {
        guard controller.connectedName != nil, continueGames.indices.contains(focus.index) else { return false }
        return continueGames[focus.index].id == game.id
    }

    // MARK: - Controller

    private func handle(_ button: ConsoleButton) {
        if selection != nil {
            if case .back = button { selection = nil }
            return
        }
        switch button {
        case .left: focus.move(-1)
        case .right: focus.move(1)
        case .select:
            if continueGames.indices.contains(focus.index) { open(continueGames[focus.index]) }
        default: break
        }
    }

    /// One push per tap: a second tap while the first push is animating could
    /// stack another game page on top of it.
    private func open(_ game: InstalledGame) {
        guard selection == nil else { return }
        selection = game
    }
}
