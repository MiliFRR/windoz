import SwiftUI

/// The download queue: pause/resume, cancel, Wi-Fi-only and progress.
struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controls
                    if manager.items.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Nothing downloading").font(.headline).foregroundStyle(.white)
                                Text("Install a game from a store, or a Windows runtime, and it appears here.")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    } else {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item, manager: manager)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Downloads")
        .onAppear { manager.restore() }
    }

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
                Button("Clear finished") { manager.clearCompletedAndFailed() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

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
