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
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if heroGames.isEmpty {
                        emptyState
                    } else {
                        carousel
                        continueRow
                        if !library.recentlyAdded.isEmpty { recentlyAddedRow }
                    }
                }
                .padding(.vertical, 18)
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
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: Theme.accent.opacity(0.5), radius: 12)
            Text("Your Windows games, on your phone")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 20)
    }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(heroGames.enumerated()), id: \.element.id) { index, game in
                        Button { selection = game } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                CoverArtView(title: game.title, imagePath: game.coverArtPath, corner: 20)
                                    .frame(width: 280, height: 380)
                                    .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
                                    .scaleEffect(focus.index == index ? 1.0 : 0.9)
                                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focus.index)
                                HStack {
                                    Text(game.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                                    Spacer()
                                    compatBadge(game.compatibility)
                                }
                                .frame(width: 280)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel("\(game.title), \(game.compatibility.title)")
                    }
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: focus.index) { _, newValue in
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
        .frame(height: 460)
    }

    @ViewBuilder private var continueRow: some View {
        let items = library.continuePlaying
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Continue playing").padding(.horizontal, 20)
                row(items)
            }
        }
    }

    @ViewBuilder private var recentlyAddedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recently added").padding(.horizontal, 20)
            row(library.recentlyAdded)
        }
    }

    private func row(_ games: [InstalledGame]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(games) { game in
                    Button { selection = game } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverArtView(title: game.title, imagePath: game.coverArtPath, corner: 12)
                                .frame(width: 132, height: 176)
                            Text(game.title).font(.caption).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1).frame(width: 132, alignment: .leading)
                            if let last = game.lastPlayedAt {
                                Text(last, style: .relative).font(.caption2).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var emptyState: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No games yet").font(.headline).foregroundStyle(.white)
                Text("Add a game from Files, or connect a store in the Library tab. DRM-free games run best.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 20)
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
        switch button {
        case .left: focus.move(-1)
        case .right: focus.move(1)
        case .select:
            let games = heroGames
            if games.indices.contains(focus.index) { selection = games[focus.index] }
        default: break
        }
    }
}
