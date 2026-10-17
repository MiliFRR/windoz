import SwiftUI
import UIKit

/// The game page: hero art, Play, an honest note about the last session, and
/// three side tabs — Overview (compatibility, anti-cheat, details),
/// Achievements and Friends (both read from Steam when signed in). The engine
/// settings live behind the toolbar gear, off the page.
struct GameDetailView: View {
    let gameID: UUID

    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var engine: WindozEngine

    @State private var launching = false
    @State private var message: String?
    @State private var tab: DetailTab = .overview
    @State private var showSettings = false
    @StateObject private var steamInfo = SteamGameInfoModel()

    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case achievements = "Achievements"
        case friends = "Friends"
        var id: String { rawValue }
    }

    private var game: InstalledGame? { library.game(withID: gameID) }

    /// The Steam appid, when this game came from Steam — the key to its
    /// achievements and friends data.
    private var steamAppID: Int? {
        guard let game, game.storeID == StoreID.steam.rawValue,
              let raw = game.storeItemID, let appID = Int(raw) else { return nil }
        return appID
    }

    var body: some View {
        ZStack {
            ConsoleBackground()
            if let game {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        hero(game)
                        playButton(game)
                        sessionNotes(game)
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(Theme.bad.opacity(0.95))
                        }
                        badges(game)
                        Picker("Section", selection: $tab) {
                            ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        switch tab {
                        case .overview: overviewTab(game)
                        case .achievements: achievementsTab(game)
                        case .friends: friendsTab(game)
                        }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Game settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            GameSettingsSheet(gameID: gameID, gameTitle: game?.title ?? "Game")
        }
        .onAppear { engine.refreshStatus() }
        .task(id: tab) {
            guard let appID = steamAppID else { return }
            switch tab {
            case .achievements: await steamInfo.loadAchievements(appID: appID)
            case .friends: await steamInfo.loadFriends(appID: appID)
            case .overview: break
            }
        }
    }

    // MARK: - Header pieces

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
            if engine.sessionsThisRun > 0, engine.sessionGame == nil {
                Text("One game per app run: Wine keeps the first session's state. Close Windoz from the app switcher and open it again to start another game.")
                    .font(.caption).foregroundStyle(Theme.warn.opacity(0.9))
            }
            if AppEnvironment.isLiveContainer, engine.status.memoryFootprintBytes > 0 {
                Text("This LiveContainer process is using \(ByteCountFormatter.string(fromByteCount: engine.status.memoryFootprintBytes, countStyle: .memory)).")
                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    /// The story of the last finished session, when it was this game.
    @ViewBuilder private func sessionNotes(_ game: InstalledGame) -> some View {
        if let outcome = engine.lastSessionOutcome, outcome.gameTitle == game.title {
            GlassCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: outcome.crashed ? "xmark.octagon.fill" : "moon.zzz.fill")
                        .foregroundStyle(outcome.crashed ? Theme.bad : Theme.ok)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.crashed ? "The last session ended with an error" : "The last session has ended")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(outcome.message)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        if outcome.seconds > 0 {
                            Text("Recorded playtime: \(outcome.seconds.playtimeDescription)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
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

    // MARK: - Overview tab

    @ViewBuilder private func overviewTab(_ game: InstalledGame) -> some View {
        if let ac = game.antiCheat { antiCheatCard(ac) }
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "You marked this")
                Picker("Compatibility", selection: compatibilityBinding) {
                    ForEach(CompatibilityStatus.allCases) { Text($0.title).tag($0) }
                }
                Text("Only you see this; it labels how the game behaved for you.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
        }
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Details")
                InfoRow(label: "Store", value: storeTitle(game))
                InfoRow(label: "Program", value: game.execName)
                InfoRow(label: "Added", value: game.addedAt.formatted(date: .abbreviated, time: .omitted))
                InfoRow(label: "Last played", value: game.lastPlayedAt.map {
                    $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "Never")
                InfoRow(label: "Playtime", value: game.playtimeSeconds.playtimeDescription)
            }
        }
    }

    @ViewBuilder private func antiCheatCard(_ ac: AntiCheatInfo) -> some View {
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

    private func storeTitle(_ game: InstalledGame) -> String {
        StoreID(rawValue: game.storeID)?.title ?? game.storeID
    }

    // MARK: - Achievements tab

    @ViewBuilder private func achievementsTab(_ game: InstalledGame) -> some View {
        if steamAppID == nil {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No achievements source", systemImage: "trophy")
                        .font(.headline).foregroundStyle(.white)
                    Text("This game did not come from Steam, so Windoz has no achievement source for it. Store pages like Steam's show them for the signed-in account only when the game has them.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                }
            }
        } else {
            switch steamInfo.achievementsState {
            case .idle, .loading:
                loadingCard("Reading achievements from Steam…")
            case .failed(let why):
                failureCard(title: "Achievements are unavailable", message: why) {
                    guard let appID = steamAppID else { return }
                    await steamInfo.loadAchievements(appID: appID)
                }
            case .loaded:
                if steamInfo.achievementRows.isEmpty {
                    GlassCard {
                        Text(steamInfo.achievementSummary)
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(steamInfo.achievementSummary)
                                .font(.headline).foregroundStyle(.white)
                            Text(steamInfo.achievementsFromCommunityXML
                                 ? "Read from your public Steam profile page (the Web API refused the stored sign-in)."
                                 : "Read from Steam's Web API with your sign-in.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    ForEach(steamInfo.achievementRows) { row in achievementRow(row) }
                }
            }
        }
    }

    private func achievementRow(_ row: SteamGameInfoModel.AchievementRow) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: URL(string: (row.unlocked ? row.iconURL : row.grayIconURL) ?? row.iconURL ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08))
                }
                .frame(width: 40, height: 40)
                .opacity(row.unlocked ? 1 : 0.65)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.unlocked ? .white : .white.opacity(0.6))
                    if !row.description.isEmpty {
                        Text(row.description)
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        if let date = row.unlockDate {
                            Text("Unlocked \(date.formatted(date: .abbreviated, time: .omitted))")
                        }
                        if let pct = row.globalPercent {
                            Text(String(format: "%.1f%% of players", pct))
                        }
                    }
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
                Image(systemName: row.unlocked ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(row.unlocked ? Theme.ok : .white.opacity(0.3))
            }
        }
    }

    // MARK: - Friends tab

    @ViewBuilder private func friendsTab(_ game: InstalledGame) -> some View {
        if steamAppID == nil {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No friends source", systemImage: "person.2")
                        .font(.headline).foregroundStyle(.white)
                    Text("This game did not come from Steam. Windoz shows friends for Steam games, read from Steam with your sign-in.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                }
            }
        } else {
            switch steamInfo.friendsState {
            case .idle, .loading:
                loadingCard(steamInfo.ownersChecked > 0
                            ? "Checking friends' public profiles… (\(steamInfo.ownersChecked)/\(min(steamInfo.ownersTotal, 20)))"
                            : "Reading your Steam friends…")
            case .failed(let why):
                failureCard(title: "Friends are unavailable", message: why) {
                    guard let appID = steamAppID else { return }
                    await steamInfo.loadFriends(appID: appID)
                }
            case .loaded:
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Playing now", systemImage: "bolt.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        if steamInfo.playingNow.isEmpty {
                            Text("No friend on your list is in this game right now.")
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                        } else {
                            ForEach(steamInfo.playingNow, id: \.steamID) { friend in
                                friendRow(friend)
                            }
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Owns this game", systemImage: "books.vertical.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        if steamInfo.owners.isEmpty {
                            Text("None of the \(steamInfo.ownersChecked) friends checked shows this game.")
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                        } else {
                            ForEach(steamInfo.owners) { owner in
                                friendRow(owner.summary ?? SteamWebAPI.PlayerSummary(
                                    steamID: owner.friend.steamID, personaName: "Steam friend",
                                    avatarURL: nil, state: 0, gameID: nil, gameName: nil))
                            }
                        }
                        Text("Checked \(steamInfo.ownersChecked) of \(steamInfo.ownersTotal) friends — public profiles only; private profiles can't be read, and Windoz never guesses them.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
    }

    private func friendRow(_ friend: SteamWebAPI.PlayerSummary) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: friend.avatarURL ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(.white.opacity(0.1))
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(friend.personaName).font(.subheadline).foregroundStyle(.white)
                if let game = friend.gameName, friend.gameID != nil {
                    Text("In \(game)").font(.caption2).foregroundStyle(Theme.ok.opacity(0.9))
                } else if friend.state > 0 {
                    Text("Online").font(.caption2).foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("Offline").font(.caption2).foregroundStyle(.white.opacity(0.35))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shared state cards

    private func loadingCard(_ text: String) -> some View {
        GlassCard {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(text).font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func failureCard(title: String, message: String, retry: @escaping () async -> Void) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.warn)
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.6))
                Button {
                    Task { await retry() }
                } label: {
                    Text("Try again").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
        }
    }

    // MARK: - Actions and bindings

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
            } catch {
                message = error.localizedDescription
            }
            launching = false
        }
    }
}

// MARK: - Settings sheet

/// The per-game engine settings, off the game page and behind the toolbar
/// gear. Everything here is saved with the game and read at the next launch.
struct GameSettingsSheet: View {
    let gameID: UUID
    let gameTitle: String

    @EnvironmentObject private var library: GameLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var settings = GameSettings.default
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                ConsoleBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Engine")
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
                        Text("Saved with the game. The launch uses the arguments, working folder, screen scale and custom switches; frame cap, sync, MetalFX and the backend choice are stored but not applied yet.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))

                        SectionHeader(title: "Controls")
                        NavigationLink {
                            TouchOverlayEditor(gameID: gameID, gameTitle: gameTitle)
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
                        Text("Saved per game. This build's session overlay does not read these controls yet — it shows a fixed key row, and touch maps 1:1 onto the game.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if let game = library.game(withID: gameID), !loaded {
                settings = game.settings
                loaded = true
            }
        }
        .onChange(of: settings) { _, newValue in
            library.setSettings(newValue, for: gameID)
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
}
