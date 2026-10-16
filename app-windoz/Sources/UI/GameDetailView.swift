import SwiftUI
import UIKit

/// The game page: hero art, Play, playtime, compatibility, the anti-cheat badge,
/// and per-game engine settings.
struct GameDetailView: View {
    let gameID: UUID

    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var engine: WindozEngine

    @State private var settings = GameSettings.default
    @State private var launching = false
    @State private var message: String?
    @State private var loaded = false

    private var game: InstalledGame? { library.game(withID: gameID) }

    var body: some View {
        ZStack {
            ConsoleBackground()
            if let game {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hero(game)
                        playButton(game)
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(Theme.bad.opacity(0.95))
                        }
                        badges(game)
                        antiCheatCard(game)
                        settingsSection
                        touchSection
                    }
                    .padding(18)
                }
            } else {
                Text("This game is no longer in the library.")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .navigationTitle(game?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let game, !loaded {
                settings = game.settings
                loaded = true
            }
            engine.refreshStatus()
        }
        .onChange(of: settings) { _, newValue in
            library.setSettings(newValue, for: gameID)
        }
    }

    // MARK: - Pieces

    private func hero(_ game: InstalledGame) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let heroPath = game.heroArtPath, let image = UIImage(contentsOfFile: heroPath) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.heroGradient
                }
            }
            .frame(height: 240)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)))

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(game.execName).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .padding(16)
        }
    }

    private func playButton(_ game: InstalledGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PrimaryButton(title: "PLAY", systemImage: "play.fill",
                          busy: launching,
                          enabled: engine.status.jit.isReady) {
                play(game)
            }
            if !engine.status.jit.isReady {
                Text(AppEnvironment.isLiveContainer
                     ? "JIT is off. Inside LiveContainer enable Launch with JIT and attach StikDebug, then come back and press Play."
                     : "JIT is off, so games cannot run yet. Enable it in Setup or Settings.")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            if AppEnvironment.isLiveContainer, engine.status.memoryFootprintBytes > 0 {
                Text("This LiveContainer process is using \(ByteCountFormatter.string(fromByteCount: engine.status.memoryFootprintBytes, countStyle: .memory)). Chromium store launchers are started only when a game needs them.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func badges(_ game: InstalledGame) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Badge(text: game.compatibility.title, systemImage: "checkmark.seal", tint: compatTint(game.compatibility))
                if let ac = game.antiCheat {
                    Badge(text: ac.kind.title, systemImage: "shield.lefthalf.filled", tint: acTint(ac.onlineRisk))
                }
                if game.requiresOnline {
                    Badge(text: "Requires online", systemImage: "wifi", tint: Theme.warn)
                }
                if game.cloudSaves {
                    Badge(text: "Cloud saves", systemImage: "icloud", tint: Theme.accent)
                }
                Badge(text: "Playtime \(game.playtimeSeconds.playtimeDescription)", systemImage: "clock", tint: .white.opacity(0.8))
            }
        }
    }

    @ViewBuilder private func antiCheatCard(_ game: InstalledGame) -> some View {
        if let ac = game.antiCheat {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Anti-cheat", systemImage: "shield.lefthalf.filled")
                            .font(.headline).foregroundStyle(.white)
                        Spacer()
                        Text(ac.onlineRisk.title).font(.caption).foregroundStyle(acTint(ac.onlineRisk))
                    }
                    Text(ac.shortExplanation)
                        .font(.footnote).foregroundStyle(.white.opacity(0.65))
                    Text("Found: \(ac.evidence)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    Text("Windoz only reports this. It never tries to bypass anti-cheat.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Settings")
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    labeled("Resolution scale", "\(Int(settings.resolutionScale * 100)) %") {
                        Slider(value: $settings.resolutionScale, in: 0.5...1.5, step: 0.05)
                    }
                    Stepper("FPS cap: \(settings.fpsCap == 0 ? "Unlimited" : "\(settings.fpsCap)")",
                            value: $settings.fpsCap, in: 0...240, step: 30)
                        .foregroundStyle(.white.opacity(0.9))
                    Toggle("MetalFX upscaling", isOn: $settings.metalFXUpscaling)
                        .foregroundStyle(.white.opacity(0.9))
                    Picker("Sync", selection: $settings.syncMode) {
                        ForEach(SyncMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Graphics backend", selection: $settings.graphicsBackend) {
                        ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Launch arguments", text: $settings.launchArguments)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                    TextField("Working directory (optional)", text: $settings.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                }
            }
            Text("Saved with the game. The engine reads these when a session starts — hosting a game session is still being ported, so nothing plays yet.")
                .font(.caption2).foregroundStyle(.white.opacity(0.45))
            Picker("Compatibility", selection: compatibilityBinding) {
                ForEach(CompatibilityStatus.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var touchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Controls")
            NavigationLink {
                TouchOverlayEditor(gameID: gameID, gameTitle: game?.title ?? "Game")
            } label: {
                GlassCard {
                    HStack {
                        Label("Touch control layout", systemImage: "hand.tap")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .buttonStyle(.plain)
            Text("Saved per game. The in-session overlay draws it once the game-session host is ported.")
                .font(.caption2).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func labeled<Content: View>(_ title: String, _ value: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(value).foregroundStyle(.white.opacity(0.55))
            }
            content()
        }
    }

    private var compatibilityBinding: Binding<CompatibilityStatus> {
        Binding(
            get: { game?.compatibility ?? .unknown },
            set: { newValue in
                guard var game = game else { return }
                game.compatibility = newValue
                library.update(game)
            })
    }

    private func compatTint(_ status: CompatibilityStatus) -> Color {
        switch status {
        case .verified: return Theme.ok
        case .playable: return Theme.accent
        case .runsPoorly: return Theme.warn
        case .unsupported: return Theme.bad
        case .unknown: return .gray
        }
    }

    private func acTint(_ risk: OnlineRisk) -> Color {
        switch risk {
        case .offlineOnly: return Theme.warn
        case .unsupported: return Theme.bad
        case .unknown: return .gray
        }
    }

    private func play(_ game: InstalledGame) {
        launching = true
        message = nil
        Task {
            do {
                try await engine.launch(game)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            launching = false
        }
    }
}
