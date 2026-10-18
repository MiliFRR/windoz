import SwiftUI

/// The Steam store sheet: the account, the account's owned library, and the
/// downloads. This is where "download the games I own" happens: each owned
/// title gets Install, live progress, Update, Verify and Uninstall, and the
/// files land in the Windows prefix in the exact layout Valve's client uses.
struct SteamLibrarySheet: View {
    @ObservedObject var store: SteamStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ConsoleBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        accountCard
                        if store.authState.isSignedIn {
                            if let message = store.libraryMessage {
                                messageCard(message)
                            }
                            librarySection
                        } else {
                            paywallCard
                        }
                    }
                    .padding(Metrics.pagePadding)
                }
                .refreshable { await refresh() }
            }
            .navigationTitle("Steam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                store.start()
                if store.authState.isSignedIn, store.games.isEmpty {
                    await refresh()
                }
            }
            // Presenting from the sheet itself: the store row's sign-in sheet
            // is a different presenter, so a sign-in started from here never
            // races the one on the Library view.
            .sheet(isPresented: $store.showingSignIn) { SteamSignInView() }
        }
    }

    // MARK: - Cards

    private var accountCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StoreIcon(id: .steam, size: 30)
                    Text("Steam").font(.headline).foregroundStyle(.white)
                    Spacer()
                    switch store.authState {
                    case .signedOut:
                        Badge(text: "Signed out", tint: .gray)
                    case .signingIn(let what):
                        Badge(text: what, tint: Theme.accent)
                    case .signedIn(let who):
                        Badge(text: who, systemImage: "person.crop.circle", tint: Theme.ok)
                    case .error(let why):
                        Text(why).font(.caption2).foregroundStyle(Theme.warn).lineLimit(3)
                    }
                }
                if store.authState.isSignedIn {
                    HStack(spacing: 12) {
                        Button {
                            Task { await refresh() }
                        } label: {
                            HStack(spacing: 6) {
                                if store.refreshing { ProgressView().controlSize(.small) }
                                Text(store.refreshing ? "Refreshing…" : "Refresh library")
                            }
                        }
                        .disabled(store.refreshing)
                        if let updated = store.libraryUpdated {
                            Text("Updated \(Self.relative.localizedString(for: updated, relativeTo: Date()))")
                                .font(.caption2).foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                        // Sign-out is one level down, under the ellipsis.
                        Menu {
                            Button("Sign out of Steam", role: .destructive) { store.signOut() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Steam account actions")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                } else {
                    Button("Sign in to Steam") { store.showingSignIn = true }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text("Downloads go to C:\\Program Files (x86)\\Steam\\steamapps inside Windoz's Windows prefix — the same layout Valve's client writes. Installing also adds the game to My games, and starting it there runs it through the game session. Downloads, updates and verification work now.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func messageCard(_ message: String) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var paywallCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to see your Steam library")
                    .font(.headline).foregroundStyle(.white)
                Text("Windoz signs in with Steam directly — password + Steam Guard, or a QR code — and stores only a token, in this device's Keychain.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder private var librarySection: some View {
        SectionHeader(title: "Owned games")
        if store.games.isEmpty {
            GlassCard {
                Text(store.refreshing ? "Loading your Steam library…" : "No owned games to show yet. Tap Refresh library.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        } else {
            ForEach(store.games) { game in
                gameCard(game)
            }
        }
    }

    private func gameCard(_ game: StoreGame) -> some View {
        let appID = UInt32(game.id) ?? 0
        let download = store.downloads[appID]
        return GlassCard {
            HStack(alignment: .top, spacing: 12) {
                coverThumb(game)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if game.installed {
                            Badge(text: "Installed", systemImage: "checkmark.circle", tint: Theme.ok)
                        }
                        if let size = game.sizeDescription {
                            Badge(text: size, tint: .white)
                        }
                    }
                    if let download {
                        downloadView(game: game, appID: appID, download: download)
                    } else {
                        actionButtons(game)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func coverThumb(_ game: StoreGame) -> some View {
        AsyncImage(url: game.coverURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(Theme.tileGradient)
                    Image(systemName: "gamecontroller")
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .frame(width: 60, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func downloadView(game: StoreGame, appID: UInt32, download: SteamStore.Download) -> some View {
        switch download.state {
        case .queued:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(download.resumable ? "Queued (resuming)…" : "Queued…")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        case .active:
            let progress = download.progress
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: progress.fraction)
                    .tint(Theme.accent)
                HStack(spacing: 10) {
                    Text(progressText(progress))
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    Button("Cancel") { store.cancelDownload(appID) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.warn)
                }
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Text(why)
                    .font(.caption).foregroundStyle(Theme.warn).lineLimit(4)
                HStack(spacing: 12) {
                    Button(download.resumable ? "Resume" : "Retry") { store.retry(game) }
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Button("Dismiss") { store.clearDownload(appID) }
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    @ViewBuilder private func actionButtons(_ game: StoreGame) -> some View {
        HStack(spacing: 12) {
            if game.installed {
                Button("Update") { perform { try await store.update(game) } }
                Button("Verify") { perform { try await store.verify(game) } }
                Button("Uninstall", role: .destructive) { perform { try await store.uninstall(game) } }
            } else {
                Button("Install") { perform { try await store.install(game) } }
                    .fontWeight(.semibold)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.accent)
    }

    // MARK: - Helpers

    private func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch {
                store.libraryMessage = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        do {
            _ = try await store.refreshLibrary()
        } catch {
            // refreshLibrary recorded the reason in libraryMessage
        }
    }

    private func progressText(_ progress: SteamDownloadProgress) -> String {
        let percent = Int((progress.fraction * 100).rounded())
        let done = ByteCountFormatter.string(fromByteCount: Int64(progress.doneBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
        if progress.fetchedBytes == 0 && progress.verifiedBytes > 0 {
            return "\(percent)% · checking files already on the device (\(done) of \(total))"
        }
        if progress.bytesPerSecond > 1 {
            let speed = ByteCountFormatter.string(fromByteCount: Int64(progress.bytesPerSecond), countStyle: .file)
            return "\(percent)% · \(done) of \(total) · \(speed)/s"
        }
        return "\(percent)% · \(done) of \(total)"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
