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
    @ObservedObject private var runtimeInstaller = RuntimeInstaller.shared
    @State private var redistItems: [GameRedistItem] = []

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
                    VStack(alignment: .leading, spacing: 16) {
                        header(game)
                        playButton(game)
                        launchModeRow(game)
                        resolutionRow(game)
                        achievementsSummary(game)
                        sessionNotes(game)
                        if let failure = engine.lastFailedLaunch, failure.gameID == gameID {
                            launchFailureCard(failure, game: game)
                        } else if let message {
                            Text(message).font(.footnote).foregroundStyle(Theme.bad.opacity(0.95))
                        }
                        if !redistItems.isEmpty {
                            redistCard(game)
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
                    .padding(Metrics.pagePadding)
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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            engine.refreshStatus()
            backfillArtworkIfNeeded()
            scanRedists()
        }
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

    private func header(_ game: InstalledGame) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CoverArtView(title: game.title,
                         imagePath: game.coverArtPath ?? game.heroArtPath,
                         corner: 10)
                .frame(width: 82, height: 110)
            VStack(alignment: .leading, spacing: 5) {
                Text(game.execName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(game.compatibility.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(compatTint(game.compatibility))
                if let antiCheat = game.antiCheat {
                    Label(antiCheat.kind.title, systemImage: "shield.lefthalf.filled")
                        .font(.caption2)
                        .foregroundStyle(Theme.warn)
                }
                if game.playtimeSeconds > 0 {
                    Text("Played \(game.playtimeSeconds.playtimeDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func playButton(_ game: InstalledGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PrimaryButton(title: "Play", systemImage: "play.fill",
                          busy: launching,
                          enabled: engine.status.jit.isReady && !engine.engineWedged) {
                play(game)
            }
            if !engine.status.jit.isReady {
                Text(AppEnvironment.isLiveContainer
                     ? "JIT is off. Inside LiveContainer enable Launch with JIT and attach StikDebug, then come back and press Play."
                     : "JIT is off, so games cannot run yet. Enable it in Setup or Settings.")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            if engine.engineWedged {
                Text("The engine is stuck from the last launch, so this app run cannot start a game again. Quit Windoz and open it again.")
                    .font(.caption).foregroundStyle(Theme.warn.opacity(0.9))
            } else if engine.sessionsThisRun > 0, engine.sessionGame == nil {
                Text("One game per app run: Wine keeps the first session's state. Quit Windoz and open it again to start another game.")
                    .font(.caption).foregroundStyle(Theme.warn.opacity(0.9))
            }
            if (engine.engineWedged || (engine.sessionsThisRun > 0 && engine.sessionGame == nil)) && !launching {
                Button {
                    AppContainer.quitNow(reason: "the run is spent — quitting from the game page")
                } label: {
                    Label("Quit Windoz", systemImage: "power")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.warn)
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

    // MARK: - Launch mode + achievements summary

    private var launchModeBinding: Binding<LaunchMode> {
        Binding(get: { library.game(withID: gameID)?.settings.launchMode ?? .direct },
                set: { mode in
                    guard var game = library.game(withID: gameID) else { return }
                    game.settings.launchMode = mode
                    library.setSettings(game.settings, for: gameID)
                })
    }

    private var resolutionBinding: Binding<GameResolution> {
        Binding(get: { library.game(withID: gameID)?.settings.resolution ?? .scaled },
                set: { resolution in
                    guard var game = library.game(withID: gameID) else { return }
                    game.settings.resolution = resolution
                    library.setSettings(game.settings, for: gameID)
                })
    }

    private var offlineBinding: Binding<Bool> {
        Binding(get: { library.game(withID: gameID)?.settings.steamOffline ?? false },
                set: { value in
                    guard var game = library.game(withID: gameID) else { return }
                    game.settings.steamOffline = value
                    library.setSettings(game.settings, for: gameID)
                })
    }

    /// How this game starts, right under Play — Direct, Doz Dock (Valve's own
    /// client inside the session, ported from Madeira Dock) or the full Steam
    /// desktop. Saved with the game; every line says what the mode really does.
    @ViewBuilder private func launchModeRow(_ game: InstalledGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Launch", selection: launchModeBinding) {
                ForEach(LaunchMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch game.settings.launchMode {
            case .direct:
                Text(directModeNote(game))
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            case .dock:
                Toggle("Steam offline sign-in (Valve's own offline mode)", isOn: offlineBinding)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Doz Dock runs Valve's own Steam client inside the session and asks it to start this game — Steam-DRM games run through Valve's client, exactly as on a PC. Nothing is faked: if Steam refuses, the reason is shown."
                     + (game.settings.steamOffline
                        ? " Offline sign-in is requested (MADEIRA_DOCK_OFFLINE=1); Steam decides whether it can sign in offline."
                        : " It needs Steam's components once (game settings → Steam launch) and a Steam sign-in in Windoz."))
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            case .steamDesktop:
                Text("The full Windows Steam client runs in the session on a virtual desktop — sign in inside it and use your library there (nothing is auto-started). Close the session like any game.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func directModeNote(_ game: InstalledGame) -> String {
        if steamAppID != nil, let exePath = engine.prefix.windowsPath(forHostPath: game.executablePath) {
            return "Direct runs the game's own program with its own Steam identity published (SteamAppPath \(exePath)); the Steam client does not run. Games that insist on the client should use Doz Dock."
        }
        return "Direct runs the game's own program. Steam games that insist on the running client can refuse — switch Launch to Doz Dock for those."
    }

    /// The game's Windows monitor, right where the game starts. Changing it
    /// here is a next-launch setting, because the engine reads
    /// MADEIRA_SCREEN_W/H once while it brings the session up.
    @ViewBuilder private func resolutionRow(_ game: InstalledGame) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Resolution", systemImage: "display")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Picker("Resolution", selection: resolutionBinding) {
                    ForEach(GameResolution.allCases) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
            }
            Text(game.settings.resolution.detail + " Takes effect at the next launch.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// Achievements, right below Play (the owner's ask): one honest summary
    /// line plus the first rows, from the same Steam data the Achievements
    /// tab shows. Hidden for games with no Steam app.
    @ViewBuilder private func achievementsSummary(_ game: InstalledGame) -> some View {
        if steamAppID != nil {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Achievements", systemImage: "trophy")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        switch steamInfo.achievementsState {
                        case .idle, .loading:
                            ProgressView().controlSize(.small)
                        case .failed:
                            Button("Retry") {
                                guard let appID = steamAppID else { return }
                                Task { await steamInfo.loadAchievements(appID: appID) }
                            }
                            .font(.caption)
                        case .loaded:
                            Text(steamInfo.achievementSummary)
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    switch steamInfo.achievementsState {
                    case .idle, .loading:
                        Text("Reading achievements from Steam…")
                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    case .failed(let why):
                        Text(why).font(.caption2).foregroundStyle(Theme.bad.opacity(0.9))
                    case .loaded:
                        if steamInfo.achievementRows.isEmpty {
                            Text("This game has no achievements.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                        } else {
                            ForEach(steamInfo.achievementRows.prefix(3)) { row in
                                HStack(spacing: 8) {
                                    Image(systemName: row.unlocked ? "trophy.fill" : "trophy")
                                        .font(.system(size: 12))
                                        .foregroundStyle(row.unlocked ? Theme.accent : .white.opacity(0.35))
                                    Text(row.name)
                                        .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                                    Spacer()
                                    if let date = row.unlockDate {
                                        Text(date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                            }
                            Button {
                                tab = .achievements
                            } label: {
                                Text("See all").font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .onAppear {
                if case .idle = steamInfo.achievementsState, let appID = steamAppID {
                    Task { await steamInfo.loadAchievements(appID: appID) }
                }
            }
        }
    }

    /// Cover art for entries that came back without it (installs made while
    /// this device refused writes). Fetched from Steam's own CDN into the
    /// resolved art directory; the log names every refusal.
    private func backfillArtworkIfNeeded() {
        guard let game, game.coverArtPath == nil, let appID = steamAppID else { return }
        Task {
            let art = await SteamStore.fetchArtwork(appID: UInt32(appID))
            guard art.cover != nil || art.hero != nil else { return }
            library.updateArtwork(id: gameID, coverPath: art.cover?.path, heroPath: art.hero?.path)
        }
    }

    // MARK: - One-time installers (_CommonRedist)

    /// Rescans the game's folder and Steam's shared redist folder. Read-only;
    /// runs when the page appears or the user taps the refresh button.
    private func scanRedists() {
        guard let game else { return }
        runtimeInstaller.refresh(prefix: engine.prefix)
        redistItems = GameRedistScanner.scan(game: game, prefix: engine.prefix)
    }

    /// The game's own one-time installers (its _CommonRedist folders, Steam's
    /// shared folder). Running one hands the vendor's installer to a real
    /// Windows session — one session per launch of Windoz, and the card says so.
    private func redistCard(_ game: InstalledGame) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(Theme.accent)
                    Text("One-time installers")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button { scanRedists() } label: { Image(systemName: "arrow.clockwise") }
                        .font(.caption)
                        .accessibilityLabel("Rescan the game's installers")
                }
                Text("This game ships the installers below. Windoz can run each in a Windows session; Windoz allows one session per launch of the app, so after it ends quit and reopen Windoz to play.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
                ForEach(redistItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.caption).foregroundStyle(.white.opacity(0.9))
                            Text("\(item.machine.label) — \(item.relativePath)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer(minLength: 8)
                        redistAction(item, game: game)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func redistAction(_ item: GameRedistItem, game: InstalledGame) -> some View {
        let key = item.ledgerKey(for: game)
        if item.machine.cannotRun {
            Text("32-bit — cannot run here").font(.caption2).foregroundStyle(Theme.warn)
        } else if case .installing = runtimeInstaller.states[key] ?? .unknown {
            Text("Session running").font(.caption2).foregroundStyle(Theme.accent)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Run") {
                    runtimeInstaller.startInstallSession(file: URL(fileURLWithPath: item.hostPath),
                                                         argsText: item.suggestedArguments,
                                                         title: item.name,
                                                         ledgerKey: key,
                                                         using: engine)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let when = runtimeInstaller.recordedRedistRun(key: key) {
                    Text("ran \(when.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    /// The launch failure card: the real error, which step stopped, one
    /// suggested repair, the step list and the log tail — plus Retry and a
    /// share sheet. It stays until the next launch starts.
    private func launchFailureCard(_ failure: LaunchFailure, game: InstalledGame) -> some View {        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Theme.bad)
                    Text("The last launch did not start")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                if let step = failure.failedStep {
                    Text("Stopped at: \(step)")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Text(failure.message)
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                if let hint = failure.hint {
                    Text("Suggested fix: \(hint)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                DisclosureGroup("The launch's steps and the last log lines") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(engine.launchSteps) { step in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: step.symbol)
                                    .font(.caption2)
                                    .foregroundStyle(step.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(step.title)
                                        .font(.caption2).foregroundStyle(.white.opacity(0.9))
                                    if !step.detail.isEmpty {
                                        Text(step.detail)
                                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                            }
                        }
                        Divider().overlay(Color.white.opacity(0.2))
                        ForEach(engine.log.recent(30)) { line in
                            Text(line.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .tint(.white.opacity(0.8))
                HStack(spacing: 12) {
                    Button {
                        play(game)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(engine.engineWedged)
                    ShareLink(item: LaunchReport.text(failure: failure,
                                                      steps: engine.launchSteps,
                                                      log: engine.log.recent(50))) {
                        Label("Copy / share report", systemImage: "square.and.arrow.up")
                    }
                    .font(.footnote)
                }
                if engine.engineWedged || engine.sessionsThisRun > 0 {
                    Button {
                        AppContainer.quitNow(reason: "quitting from the failed-launch card")
                    } label: {
                        Label("Quit Windoz", systemImage: "power")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.warn)
                }
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
    @EnvironmentObject private var engine: WindozEngine
    @Environment(\.dismiss) private var dismiss

    @State private var settings = GameSettings.default
    @State private var loaded = false
    @State private var environmentText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var steamReady = false
    @State private var installingSteam = false
    @State private var steamStage: String?
    @State private var steamError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ConsoleBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        steamLaunchCard
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Display")
                                Picker("Game resolution", selection: $settings.resolution) {
                                    ForEach(GameResolution.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                note(settings.resolution.detail, applied: true)
                                if settings.resolution == .scaled {
                                    labeled("Render scale", "\(Int(settings.resolutionScale * 100)) %") {
                                        Slider(value: $settings.resolutionScale, in: 0.5...1.5, step: 0.05)
                                    }
                                    note("Applied — the guest monitor is 1280 × 720 times this at launch.", applied: true)
                                }
                                Text("The Windows monitor the game renders into. It is aspect-fitted to the phone at the next launch.")
                                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
                                Picker("Frame pacing", selection: $settings.fpsLimit) {
                                    ForEach(FPSLimit.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                note("Applied — the engine's own frame-pacing call at session start.", applied: true)
                                Picker("Present mode", selection: $settings.syncMode) {
                                    ForEach(SyncMode.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                note("Stored — this build's engine has no switch for it.", applied: false)
                                Toggle("MetalFX upscaling", isOn: $settings.metalFXUpscaling)
                                    .foregroundStyle(.white.opacity(0.9))
                                note("Stored — not applied by this build.", applied: false)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Emulation & performance")
                                Picker("Sync engine", selection: $settings.syncEngine) {
                                    ForEach(SyncEngineChoice.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                note("Applied — MADEIRA_FASTSYNC at launch.", applied: true)
                                Toggle("AVX and AVX2 (128-bit emulation)", isOn: $settings.fexAVX)
                                    .foregroundStyle(.white.opacity(0.9))
                                Toggle("Reduced-precision x87", isOn: $settings.reducedX87)
                                    .foregroundStyle(.white.opacity(0.9))
                                Stepper("CPU count: \(settings.cpuCount == 0 ? "Automatic" : "\(settings.cpuCount)")",
                                        value: $settings.cpuCount, in: 0...12)
                                    .foregroundStyle(.white.opacity(0.9))
                                note("Applied — MADEIRA_FEX_AVX / FEX_X87REDUCEDPRECISION / MADEIRA_CPU_COUNT at launch.", applied: true)
                                Picker("Anisotropic filtering", selection: $settings.anisotropyLimit) {
                                    Text("Automatic").tag(0)
                                    Text("1×").tag(1)
                                    Text("2×").tag(2)
                                    Text("4×").tag(4)
                                    Text("8×").tag(8)
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                note("Applied — DXMT_D9_ANISO_LIMIT at launch.", applied: true)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Windows behaviour")
                                Picker("Game windows", selection: $settings.gameWindows) {
                                    ForEach(TriState.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                Picker("Virtual display mode", selection: $settings.virtualModeSet) {
                                    ForEach(TriState.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                Toggle("Stay in-session for launcher child processes", isOn: $settings.waitChildren)
                                    .foregroundStyle(.white.opacity(0.9))
                                note("Applied — MADEIRA_GAME_WINDOWS / MADEIRA_VIRTUAL_MODE_SET / MADEIRA_WAIT_CHILDREN at launch.", applied: true)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Input & graphics backend")
                                Toggle("Also expose a DirectInput joystick", isOn: $settings.dinputPad)
                                    .foregroundStyle(.white.opacity(0.9))
                                note("XInput is always available to controller layouts. This adds Wine's DirectInput joystick beside it for older games (MADEIRA_DINPUT_PAD=1). Applied at the next launch; a running session cannot change it.", applied: true)
                                    .foregroundStyle(.white.opacity(0.9))
                                Picker("Graphics backend", selection: $settings.graphicsBackend) {
                                    ForEach(GraphicsBackend.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                note("Stored — not applied by this build.", applied: false)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Launch")
                                TextField("Launch arguments", text: $settings.launchArguments)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.white)
                                TextField("Working directory (optional)", text: $settings.workingDirectory)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.white)
                                Text("Extra environment (KEY=value per line)")
                                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                                TextEditor(text: $environmentText)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .scrollContentBackground(.hidden)
                                    .background(.white.opacity(0.06))
                                    .frame(minHeight: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                note("Applied — arguments, working folder and every KEY=value line go to the launch unchanged.", applied: true)
                            }
                        }
                        Text("Green = this build really applies it at launch (the exact engine call or variable is named above). Amber = saved with the game but not applied yet.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))

                        SectionHeader(title: "Controls")
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Layout", selection: $settings.controlLayout) {
                                    ForEach(ControlLayout.allCases) { Text($0.title).tag($0) }
                                }
                                .foregroundStyle(.white.opacity(0.9))
                                Text(controlLayoutExplanation)
                                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                                note("Applied — the session shows this layout's controls, and a connected controller reaches the game this way. Changeable while the game runs from the ⚙ menu in the session.", applied: true)
                            }
                        }
                    }
                    .padding(Metrics.pagePadding)
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
                environmentText = formatEnvironment(game.settings.environment)
                loaded = true
            }
            checkSteamComponents()
        }
        .onChange(of: settings) { _, newValue in
            // Debounced: a text field in the sheet saves per keystroke
            // otherwise, and every save touches the file *and* the Keychain
            // mirror.
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                library.setSettings(newValue, for: gameID)
            }
        }
        .onChange(of: environmentText) { _, newValue in
            let parsed = parseEnvironment(newValue)
            if parsed != settings.environment { settings.environment = parsed }
        }
    }

    /// The Steam launch section: mode, offline request, and Valve's client
    /// components (fetched from Valve's own CDN, hash-pinned — no Valve binary
    /// is bundled with the app). This is what makes Doz Dock and the Steam
    /// desktop session possible.
    private var steamLaunchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Steam launch")
                Picker("Launch mode", selection: $settings.launchMode) {
                    ForEach(LaunchMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch settings.launchMode {
                case .direct:
                    note("Applied — the game's own program runs; its Steam identity is published when it sits inside Windows.", applied: true)
                case .dock:
                    note("Applied — MADEIRA_DOCK_SESSION=1: Valve's own Steam client runs in the session (port of Madeira Dock) and starts the game through Steam itself.", applied: true)
                    Toggle("Steam offline sign-in (Valve's own offline mode)", isOn: $settings.steamOffline)
                        .foregroundStyle(.white.opacity(0.9))
                    note("Applied — MADEIRA_DOCK_OFFLINE=1 when on (or when the device has no network path). Valve's client decides what it can do offline.", applied: true)
                case .steamDesktop:
                    note("Applied — the full Windows Steam client runs on a virtual desktop (steam.exe); sign in inside the session.", applied: true)
                }
                Divider().overlay(.white.opacity(0.15))
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: steamReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(steamReady ? Theme.ok : Theme.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(steamReady ? "Steam's Windows components are ready"
                                        : "Steam's Windows components are not installed")
                            .font(.footnote).foregroundStyle(.white)
                        Text("Valve's own client files (about 72 MB) fetched from Valve's update CDN and checked against pinned sizes and SHA-256. Without them, Steam-DRM games cannot run through Steam.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
                if installingSteam {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(steamStage ?? "Preparing…").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                } else if let steamError {
                    Text(steamError).font(.caption2).foregroundStyle(Theme.bad.opacity(0.95))
                }
                if !steamReady && !installingSteam {
                    Button("Download Steam's components") { installSteamComponents() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
        }
    }

    private func checkSteamComponents() {
        let root = engine.prefix.url.appendingPathComponent("drive_c/\(SteamClientRuntime.relativeRoot)")
        steamReady = FileManager.default.fileExists(atPath: root.appendingPathComponent("steamclient64.dll").path)
    }

    private func installSteamComponents() {
        installingSteam = true
        steamError = nil
        steamStage = "Preparing…"
        let prefix = engine.prefix
        Task {
            do {
                try await SteamClientInstaller.shared.prepare(prefix: prefix) { stage in
                    await MainActor.run { self.steamStage = stage }
                }
                await MainActor.run {
                    self.installingSteam = false
                    self.steamStage = nil
                    self.checkSteamComponents()
                }
            } catch {
                await MainActor.run {
                    self.installingSteam = false
                    self.steamStage = nil
                    self.steamError = error.localizedDescription
                }
            }
        }
    }

    private func note(_ text: String, applied: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: applied ? "checkmark.circle.fill" : "tray.full")
                .font(.system(size: 10))
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(applied ? Theme.ok.opacity(0.9) : Theme.warn.opacity(0.85))
    }

    /// One honest sentence per layout: what the session shows, and what the
    /// game is told it has.
    private var controlLayoutExplanation: String {
        switch settings.controlLayout {
        case .keyboardMouse:
            return "The session shows the key row, and touch acts as the game's own pointer. A connected controller becomes keyboard and mouse (WASD, the mouse on the right stick, the template keys on the buttons) — the game is not told a controller exists."
        case .xbox:
            return "The session shows Xbox controls. A connected controller and the on-screen pad merge into one Xbox-style pad in slot 0."
        case .playStation:
            return "The session shows PlayStation 5 controls on the same pad the engine publishes: the game is told it has an Xbox-style controller, not a DualSense."
        }
    }

    private func parseEnvironment(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private func formatEnvironment(_ dict: [String: String]) -> String {
        dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
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
