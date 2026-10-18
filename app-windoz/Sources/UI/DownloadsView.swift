import SwiftUI

/// The download queue — one screen for every download the app knows how to
/// watch: Steam installs (Windoz's own depot downloader), Epic's chunked
/// installer, and the general Windoz queue (launcher installers, runtimes).
///
/// Device report (2026-10-18): "game download not showing up in the downloads
/// tab". Steam and Epic game downloads lived only inside their own library
/// sheets, so this tab said "Nothing downloading" while a game genuinely was.
/// Every store's live download now lands here, with the same controls its own
/// sheet offers.
struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @ObservedObject private var registry = StoreRegistry.shared
    @ObservedObject private var steam = StoreRegistry.shared.steam
    @ObservedObject private var epic = StoreRegistry.shared.epic

    var body: some View {
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    if everythingIsQuiet {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Nothing downloading").font(.headline).foregroundStyle(.white)
                                Text("Install a game from a store, or a Windows runtime, and it appears here.")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                    steamSection
                    epicSection
                    windozSection
                }
                .padding(20)
            }
        }
        .navigationTitle("Downloads")
        .onAppear { manager.restore() }
    }

    private var everythingIsQuiet: Bool {
        manager.items.isEmpty && steam.downloads.isEmpty && epic.download == nil
    }

    // MARK: - The general queue

    @ViewBuilder private var windozSection: some View {
        if !manager.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Windoz queue")
                ForEach(manager.items) { item in
                    DownloadRow(item: item, manager: manager)
                }
            }
        }
    }

    // MARK: - Steam

    @ViewBuilder private var steamSection: some View {
        let entries = steam.downloads.sorted { $0.key < $1.key }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Steam")
                ForEach(entries, id: \.key) { appID, download in
                    SteamDownloadRow(store: steam, appID: appID, download: download)
                }
            }
        }
    }

    // MARK: - Epic

    @ViewBuilder private var epicSection: some View {
        if let state = epic.download {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Epic Games")
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(epicTitle(state)).font(.headline).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Badge(text: state.phase, tint: Theme.accent)
                        }
                        if state.totalBytes > 0 {
                            ProgressView(value: state.fraction).tint(Theme.accent)
                        }
                        Text(epicDetail(state))
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                        HStack(spacing: 14) {
                            if state.isPaused {
                                Button("Resume") { epic.resumeDownload() }
                            } else {
                                Button("Pause") { epic.pauseDownload() }
                            }
                            Button("Cancel", role: .destructive) { epic.cancelDownload() }
                            Spacer()
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote.weight(.semibold))
                    }
                }
            }
        }
    }

    private func epicTitle(_ state: EpicStore.DownloadState) -> String {
        epic.games.first { $0.id == state.gameID }?.title ?? "Epic download"
    }

    private func epicDetail(_ state: EpicStore.DownloadState) -> String {
        var parts: [String] = [state.detail.isEmpty ? state.phase : state.detail]
        if state.totalBytes > 0 {
            let done = ByteCountFormatter.string(fromByteCount: Int64(state.doneBytes), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(state.totalBytes), countStyle: .file)
            parts.append("\(Int(state.fraction * 100))% · \(done) of \(total)")
        }
        if state.speedBytesPerSecond > 1 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(state.speedBytesPerSecond), countStyle: .file) + "/s")
        }
        if let eta = state.etaSeconds, eta > 1 {
            parts.append("\(Int(eta))s left")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Controls

    private var controls: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Download over Wi-Fi only", isOn: Binding(
                    get: { manager.wifiOnly },
                    set: { manager.setWifiOnly($0) }))
                    .foregroundStyle(.white.opacity(0.9))
                if manager.onExpensiveConnection && manager.wifiOnly {
                    Text("You are on a metered connection, so downloads are held.")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
                if AppEnvironment.isLiveContainer {
                    Text("Inside LiveContainer, iOS will not continue these transfers after Windoz is closed. Leave this screen (or a LiveContainer window) open until they finish.")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
                if !manager.items.isEmpty {
                    Button("Clear finished") { manager.clearCompletedAndFailed() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

// MARK: - Steam row

private struct SteamDownloadRow: View {
    let store: SteamStore
    let appID: UInt32
    let download: SteamStore.Download

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(download.title.isEmpty ? "App \(appID)" : download.title)
                        .font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    stateBadge
                }
                switch download.state {
                case .queued:
                    Text(download.resumable
                         ? "Queued (resuming — the finished parts are kept)…"
                         : "Queued…")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                case .active:
                    let progress = download.progress
                    ProgressView(value: progress.fraction).tint(Theme.accent)
                    HStack(spacing: 12) {
                        Text(Self.progressText(progress))
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Button("Cancel") { store.cancelDownload(appID) }
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.warn)
                    }
                case .failed(let why):
                    Text(why)
                        .font(.caption).foregroundStyle(Theme.warn).lineLimit(4)
                    HStack(spacing: 14) {
                        if let game = store.games.first(where: { $0.id == String(appID) }) {
                            Button(download.resumable ? "Resume" : "Retry") { store.retry(game) }
                        }
                        Button("Dismiss") { store.clearDownload(appID) }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder private var stateBadge: some View {
        switch download.state {
        case .queued: Badge(text: "Queued", tint: .gray)
        case .active: Badge(text: "Downloading", systemImage: "arrow.down", tint: Theme.accent)
        case .failed: Badge(text: "Stopped", tint: Theme.warn)
        }
    }

    static func progressText(_ progress: SteamDownloadProgress) -> String {
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
}

// MARK: - The Windoz queue row

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var manager: DownloadManager

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    stateBadge
                }
                if item.totalBytes > 0 {
                    ProgressView(value: item.progress).tint(Theme.accent)
                    HStack {
                        Text("\(Int(item.progress * 100)) %").font(.caption).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(byteText).font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                HStack(spacing: 14) {
                    switch item.state {
                    case .downloading:
                        Button("Pause") { manager.pause(item.id) }
                    case .paused, .queued:
                        Button("Resume") { manager.resume(item.id) }
                    default:
                        EmptyView()
                    }
                    Button("Cancel", role: .destructive) { manager.cancel(item.id) }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .font(.footnote.weight(.semibold))
            }
        }
    }

    @ViewBuilder private var stateBadge: some View {
        switch item.state {
        case .queued: Badge(text: "Queued", tint: .gray)
        case .downloading: Badge(text: speedText, systemImage: "arrow.down", tint: Theme.accent)
        case .paused: Badge(text: "Paused", tint: Theme.warn)
        case .verifying: Badge(text: "Verifying", tint: Theme.accent)
        case .completed: Badge(text: "Done", systemImage: "checkmark", tint: Theme.ok)
        case .failed(let why): Text(why).font(.caption2).foregroundStyle(Theme.bad).lineLimit(3)
        }
    }

    private var speedText: String {
        let speed = ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file)
        if item.etaSeconds > 0 { return "\(speed)/s · \(Int(item.etaSeconds))s" }
        return "\(speed)/s"
    }

    private var byteText: String {
        let done = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
        return "\(done) of \(total)"
    }
}
