import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @StateObject private var engine = WindozEngine.shared
    @StateObject private var store = LocalGameStore()
    @State private var showingImporter = false
    @State private var engineMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.07), .black],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        statusCard
                        Text("MY GAMES")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.45))
                            .tracking(3)
                        if store.games.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.games) { game in
                                NavigationLink(value: game) {
                                    GameRow(game: game)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        addGameButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
            .navigationTitle("")
            .navigationDestination(for: LocalGame.self) { game in
                GameDetailView(game: game)
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let name = url.lastPathComponent.replacingOccurrences(of: ".exe", with: "")
                    store.add(title: name.isEmpty ? url.lastPathComponent : name,
                              exePath: url.path)
                }
            }
            .onAppear { engine.refreshStatus() }
            .alert("Engine", isPresented: .constant(engineMessage != nil)) {
                Button("OK", role: .cancel) { engineMessage = nil }
            } message: {
                Text(engineMessage ?? "")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("windoz")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .blue.opacity(0.4), radius: 10)
            Text("Windows games, in your pocket")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            statusBadge("bolt.fill", "JIT", engine.status.jit)
            statusBadge("memorychip", "Memory+", engine.status.memoryEntitlement)
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "internaldrive").font(.system(size: 16))
                Text("Storage")
                Text(ByteCountFormatter.string(fromByteCount: engine.status.freeStorageBytes, countStyle: .file))
                    .font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.8))
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
    }

    private func statusBadge(_ icon: String, _ label: String, _ health: EngineHealth) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
            Text(label).font(.caption)
            Text(text(for: health))
                .font(.caption2)
                .foregroundStyle(color(for: health))
        }
        .foregroundStyle(color(for: health) == .green ? .green : .white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }

    private func text(for health: EngineHealth) -> String {
        switch health {
        case .ready: return "OK"
        case .unavailable: return "OFF"
        case .checking: return "…"
        case .unknown: return "—"
        }
    }

    private func color(for health: EngineHealth) -> Color {
        switch health {
        case .ready: return .green
        case .checking: return .yellow
        case .unavailable: return .red
        case .unknown: return .gray
        }
    }

    private var emptyState: some View {
        Text("No games yet. Add a game folder from the Files app — or sign in to a store once store support lands.")
            .font(.callout)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.vertical, 10)
    }

    private var addGameButton: some View {
        Button { showingImporter = true } label: {
            Label("Add game from Files", systemImage: "plus.circle.fill")
                .font(.system(.headline, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

struct GameRow: View {
    let game: LocalGame

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.30, blue: 0.55),
                                              Color(red: 0.05, green: 0.08, blue: 0.18)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "gamecontroller").foregroundStyle(.white.opacity(0.4)))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline).foregroundStyle(.white)
                Text(game.exePath.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.3))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }
}
