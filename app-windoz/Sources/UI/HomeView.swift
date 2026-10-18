import SwiftUI

/// The console home screen: a large cover-art carousel, then Continue Playing
/// and Recently Added rows. Controller-driven and VoiceOver-labelled.
struct HomeView: View {
    @EnvironmentObject private var library: GameLibrary
    @ObservedObject private var controller = ControllerManager.shared
    @StateObject private var focus = ConsoleFocus()
    @State private var selection: InstalledGame?

    private var heroGames: [InstalledGame] {
        library.recentlyAdded.isEmpty ? library.games : library.recentlyAdded
    }

    var body: some View {
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if heroGames.isEmpty {
                        emptyState
                    } else {
                        carousel
                        continueRow
                        if !library.recentlyAdded.isEmpty { recentlyAddedRow }
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .navigationDestination(item: $selection) { game in
            GameDetailView(gameID: game.id)
        }
        .onAppear {
            focus.count = heroGames.count
            controller.onButton = handle
        }
        .onDisappear { controller.onButton = nil }
        .onChange(of: heroGames.count) { _, newValue in
            focus.count = newValue
            focus.reset()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Windoz")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Theme.accent.opacity(0.45), radius: 10)
            Text("Your Windows games, on your phone")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(heroGames.enumerated()), id: \.element.id) { index, game in
                        Button { open(game) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CoverArtView(title: game.title, imagePath: game.coverArtPath, corner: Metrics.cardCorner)
                                    .frame(width: Metrics.heroTileWidth, height: Metrics.heroTileHeight)
                                    .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
                                    .scaleEffect(focus.index == index ? 1.0 : 0.94)
                                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focus.index)
                                HStack {
                                    Text(game.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    Spacer()
                                    compatBadge(game.compatibility)
                                }
                                .frame(width: Metrics.heroTileWidth)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel("\(game.title), \(game.compatibility.title)")
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
            }
            .onChange(of: focus.index) { _, newValue in
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
        .frame(height: 330)
    }

    @ViewBuilder private var continueRow: some View {
        let items = library.continuePlaying
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Continue playing").padding(.horizontal, Metrics.pagePadding)
                row(items)
            }
        }
    }

    @ViewBuilder private var recentlyAddedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recently added").padding(.horizontal, Metrics.pagePadding)
            row(library.recentlyAdded)
        }
    }

    private func row(_ games: [InstalledGame]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(games) { game in
                    Button { open(game) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverArtView(title: game.title, imagePath: game.coverArtPath, corner: Metrics.tileCorner)
                                .frame(width: Metrics.shelfTileWidth, height: Metrics.shelfTileHeight)
                            Text(game.title).font(.caption).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1).frame(width: Metrics.shelfTileWidth, alignment: .leading)
                            if let last = game.lastPlayedAt {
                                Text(Self.relativeText(last)).font(.caption2).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    /// Static "2m ago"-style text. `Text(_:style:)` re-renders on a system
    /// clock while visible; a formatted string costs nothing between updates.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeText(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private var emptyState: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No games yet").font(.headline).foregroundStyle(.white)
                Text("Add a game from Files, or connect a store in the Library tab. DRM-free games run best.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    private func compatBadge(_ status: CompatibilityStatus) -> some View {
        Badge(text: status.title, systemImage: "checkmark.seal", tint: tint(status))
    }

    private func tint(_ status: CompatibilityStatus) -> Color {
        switch status {
        case .verified: return Theme.ok
        case .playable: return Theme.accent
        case .runsPoorly: return Theme.warn
        case .unsupported: return Theme.bad
        case .unknown: return .gray
        }
    }

    // MARK: - Controller

    private func handle(_ button: ConsoleButton) {
        // While a game page is pushed, the shelf underneath must stay quiet:
        // a stray Select used to re-point the navigation at a different game.
        // Back is the way out, mirroring the nav bar.
        if selection != nil {
            if case .back = button { selection = nil }
            return
        }
        switch button {
        case .left: focus.move(-1)
        case .right: focus.move(1)
        case .select:
            let games = heroGames
            if games.indices.contains(focus.index) { open(games[focus.index]) }
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
