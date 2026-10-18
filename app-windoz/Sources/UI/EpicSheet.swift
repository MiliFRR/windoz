import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// Epic sign-in: a device code the owner approves on epicgames.com/activate.
/// Windoz shows the code (and a QR that opens the approval page), polls Epic
/// until the owner approves, and stores only the issued token in the Keychain.
struct EpicSignInSheet: View {
    @ObservedObject var store: EpicStore
    @StateObject private var controller = EpicSignInController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ConsoleBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch controller.stage {
                        case .idle:
                            introCard
                        case .requesting:
                            progressCard("Asking Epic for a sign-in code…")
                        case .waiting(let userCode, let url, _):
                            waitingCard(userCode: userCode, url: url)
                        case .finishing:
                            progressCard("Finishing sign-in…")
                        case .done:
                            successCard
                        case .failed(let why):
                            failedCard(why)
                        }
                    }
                    .padding(Metrics.pagePadding)
                }
            }
            .navigationTitle("Epic sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if controller.stage == .idle { controller.begin() }
            }
            .onChange(of: controller.stage) { _, newValue in
                if newValue == .done { dismiss() }
            }
            .onDisappear { controller.cancel() }
        }
    }

    // MARK: - Cards

    private var introCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to Epic")
                    .font(.headline).foregroundStyle(.white)
                Text("Windoz asks Epic for a one-time code. You approve it on Epic's own website — your password is never typed into this app and never seen by it. Only the issued sign-in token is kept, in this device's Keychain.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                Button("Start sign-in") { controller.begin() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func progressCard(_ text: String) -> some View {
        GlassCard {
            HStack(spacing: 10) {
                ProgressView()
                Text(text).font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func waitingCard(userCode: String, url: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Approve this code on Epic's site")
                    .font(.headline).foregroundStyle(.white)
                HStack(spacing: 12) {
                    Text(userCode)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = userCode
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                if let image = qrImage(for: url) {
                    HStack {
                        Spacer()
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                        Spacer()
                    }
                }
                if let link = URL(string: url) {
                    Link(destination: link) {
                        Label("Open epicgames.com/activate", systemImage: "safari")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval… the code lasts about ten minutes.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Button("Cancel") { controller.cancel() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    private var successCard: some View {
        GlassCard {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                Text("Signed in to Epic. Loading your library…")
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func failedCard(_ why: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    Text(why).font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                Button("Try again") { controller.begin() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - QR

    private func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The Epic store sheet: the account, the owned library, and the chunked
/// download that fetches a title's live Windows build from Epic's own CDN.
/// Every row shows what is actually happening — a phase and byte count while
/// downloading, "Installed" when done — never a button that cannot work.
struct EpicSheet: View {
    @ObservedObject var store: EpicStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLauncherSignIn = false

    var body: some View {
        NavigationStack {
            ZStack {
                ConsoleBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        accountCard
                        if store.authState.isSignedIn {
                            launcherCard
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
            .navigationTitle("Epic Games")
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
            .sheet(isPresented: $store.showingSignIn) { EpicSignInSheet(store: store) }
            .sheet(isPresented: $showLauncherSignIn) { EpicLauncherSignInSheet() }
        }
    }

    // MARK: - Cards

    private var accountCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StoreIcon(id: .epic, size: 30)
                    Text("Epic Games").font(.headline).foregroundStyle(.white)
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
                        Menu {
                            Button("Sign out of Epic", role: .destructive) { store.signOut() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Epic account actions")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                } else {
                    Button("Sign in to Epic") { store.showingSignIn = true }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text("Sign-in uses Epic's device code: you approve it on epicgames.com/activate and Windoz never sees your password. Downloads come from Epic's own CDN and every chunk is hash-verified before it is written.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// The launcher-scoped session: Epic's library service answers only to
    /// the launcher client, so the library uses this sign-in when it exists.
    private var launcherCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "safari")
                        .foregroundStyle(Theme.accent)
                    Text("Launcher library session").font(.headline).foregroundStyle(.white)
                    Spacer()
                    if store.launcherSignedIn {
                        Badge(text: EpicLauncherSignIn.accountName ?? "Connected",
                              systemImage: "person.crop.circle", tint: Theme.ok)
                    } else {
                        Badge(text: "Not connected", tint: .gray)
                    }
                }
                Text("Epic scopes its library service to the launcher client. This sign-in opens Epic's own page — the password never touches Windoz, the web view keeps no cookies, and only the session Epic issues is kept in this device's Keychain.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 14) {
                    if store.launcherSignedIn {
                        Button("Refresh library") { Task { await refresh() } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Menu {
                            Button("Sign out of the launcher session", role: .destructive) {
                                EpicLauncherSignIn.signOut()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Launcher session actions")
                    } else {
                        Button("Sign in with the launcher") { showLauncherSignIn = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
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
                Text("Sign in to see your Epic library")
                    .font(.headline).foregroundStyle(.white)
                Text("Windoz shows your owned titles with real art. No password is ever typed into the app — you approve a code on Epic's own site.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder private var librarySection: some View {
        SectionHeader(title: "Owned games")
        if store.games.isEmpty {
            GlassCard {
                Text(store.refreshing ? "Loading your Epic library…" : "No owned games to show yet. Tap Refresh library.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
        } else {
            ForEach(store.games) { game in
                gameCard(game)
            }
        }
    }

    private func gameCard(_ game: StoreGame) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                coverThumb(game)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let developer = game.subtitle, !developer.isEmpty {
                        Text(developer)
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    if let download = store.download, download.gameID == game.id {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: download.fraction)
                                .tint(Theme.accent)
                            Text("\(download.phase.capitalized) — \(download.detail)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                            if !download.isPaused, download.speedBytesPerSecond > 1 {
                                Text(downloadProgressLine(download))
                                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            HStack(spacing: 12) {
                                Button(download.isPaused ? "Resume" : "Pause") {
                                    if download.isPaused { store.resumeDownload() } else { store.pauseDownload() }
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                Button("Cancel") { store.cancelDownload() }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red.opacity(0.9))
                            }
                            .buttonStyle(.plain)
                        }
                    } else if game.installed {
                        Badge(text: "Installed", systemImage: "checkmark.circle.fill", tint: Theme.ok)
                    } else {
                        HStack(spacing: 10) {
                            Button {
                                install(game)
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle.fill")
                                    .font(.footnote.weight(.semibold))
                            }
                            .foregroundStyle(Theme.accent)
                            .disabled(store.download != nil)
                            if let size = game.sizeDescription {
                                Text(size).font(.caption2).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func install(_ game: StoreGame) {
        Task {
            do {
                try await store.install(game)
            } catch {
                // The real sentence, not the error's type name: Phase 6
                // requires every refusal to read honestly in the UI.
                store.libraryMessage = EpicStore.message(error)
            }
        }
    }

    /// "3.4 MB/s — about 2 min left" for the running download.
    private func downloadProgressLine(_ download: EpicStore.DownloadState) -> String {
        let speed = ByteCountFormatter.string(fromByteCount: Int64(download.speedBytesPerSecond), countStyle: .file) + "/s"
        guard let eta = download.etaSeconds, eta > 1 else { return speed }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = eta >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        guard let text = formatter.string(from: eta) else { return speed }
        return "\(speed) — about \(text) left"
    }

    private func coverThumb(_ game: StoreGame) -> some View {
        AsyncImage(url: game.coverURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(Theme.tileGradient)
                    Image(systemName: "e.square")
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .frame(width: 60, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private func refresh() async {
        do {
            _ = try await store.refreshLibrary()
        } catch {
            // refreshLibrary recorded the reason in libraryMessage
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
