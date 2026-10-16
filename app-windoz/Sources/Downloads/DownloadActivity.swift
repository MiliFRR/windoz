import Foundation
import ActivityKit
import UserNotifications

/// Live Activity payload for a download. The attributes are declared here so the
/// app can start/update/end activities; rendering them in the Dynamic Island and
/// on the Lock Screen needs the paired widget extension (see docs/ROADMAP.md —
/// it is the one remaining piece of the Live Activity feature).
struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double
        var receivedBytes: Int64
        var totalBytes: Int64
        var bytesPerSecond: Double
        var etaSeconds: Double
        var stateText: String
    }

    var title: String
}

/// Shows download progress (title, percent, speed, ETA) as a Live Activity where
/// the system allows it, and falls back to a local notification banner so the
/// user still sees progress if activities are unavailable.
final class DownloadActivity {
    static let shared = DownloadActivity()

    private var activities: [UUID: Activity<DownloadActivityAttributes>] = [:]

    private init() {}

    func update(for item: DownloadItem) {
        let state = DownloadActivityAttributes.ContentState(
            progress: item.progress,
            receivedBytes: item.receivedBytes,
            totalBytes: item.totalBytes,
            bytesPerSecond: item.bytesPerSecond,
            etaSeconds: item.etaSeconds,
            stateText: stateText(for: item))

        if let existing = activities[item.id] {
            Task { await existing.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            postFallbackNotification(for: item)
            return
        }
        do {
            let activity = try Activity.request(
                attributes: DownloadActivityAttributes(title: item.title),
                content: ActivityContent(state: state, staleDate: nil))
            activities[item.id] = activity
        } catch {
            // No widget extension / activities refused — keep going quietly.
            postFallbackNotification(for: item)
        }
    }

    func finish(for id: UUID) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        Task { await activity.end(nil, dismissalPolicy: .after(.now + 5)) }
    }

    private func stateText(for item: DownloadItem) -> String {
        switch item.state {
        case .queued: return "Waiting"
        case .downloading:
            let speed = ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file)
            let eta = item.etaSeconds > 0 ? " · \(Int(item.etaSeconds))s left" : ""
            return "\(speed)/s\(eta)"
        case .paused: return "Paused"
        case .verifying: return "Verifying…"
        case .completed: return "Done"
        case .failed(let why): return why
        }
    }

    private func postFallbackNotification(for item: DownloadItem) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Downloading \(item.title)"
            content.body = "\(Int(item.progress * 100))%"
            center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
        }
    }
}
