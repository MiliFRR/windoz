import Foundation
import UIKit
import BackgroundTasks

/// A best-effort extension for game installs whose network loop is app code.
///
/// Steam depot chunks and Epic chunks are many small requests driven by the
/// install task, not one file handed to `URLSession`. They cannot be moved to a
/// background `URLSession` without rewriting both installers. What iOS does
/// allow is a short `beginBackgroundTask` grace period and, later, one
/// `BGProcessingTask` window. Both are taken here; neither is claimed to keep a
/// multi-gigabyte install running indefinitely. The runtime/launcher queue in
/// `DownloadManager` uses a real background URLSession and does continue.
@MainActor
final class GameDownloadBackground {
    static let shared = GameDownloadBackground()

    /// The build-time Info.plist identifier (it is not rewritten when the app
    /// is re-signed). BGTaskScheduler only accepts an identifier from that
    /// list, so pick the one this app owns rather than composing the live id.
    static var processingIdentifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.first { $0.hasSuffix(".download") && !$0.contains("$(") }
    }

    private var active = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var processingTask: BGProcessingTask?
    private var registered = false

    private init() {}

    func register() {
        guard !AppEnvironment.isLiveContainer else { return }
        // SwiftUI's app init and the UIKit delegate both call this; the second
        // call is a no-op, not a missing-identifier warning.
        guard !registered else { return }
        guard let identifier = Self.processingIdentifier else {
            EngineLogStream.shared.append("[downloads] game installs cannot take a background processing window: no permitted .download identifier is in this build.", level: .warning)
            return
        }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                guard let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.processingTask = processing
                processing.expirationHandler = { [weak self] in
                    Task { @MainActor in self?.expireProcessingTask() }
                }
                self.beginBackgroundTask()
                if self.active == 0 {
                    self.finishProcessingTask(success: true)
                    self.endBackgroundTask()
                }
            }
        }
    }

    /// Call when a Steam/Epic install starts.
    func begin() {
        guard !AppEnvironment.isLiveContainer else { return }
        active += 1
        beginBackgroundTask()
        scheduleProcessingTask()
    }

    /// Call when that install ends, however it ends.
    func end() {
        guard active > 0 else { return }
        active -= 1
        guard active == 0 else { return }
        endBackgroundTask()
        finishProcessingTask(success: true)
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "windoz.game-download") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func scheduleProcessingTask() {
        guard let identifier = Self.processingIdentifier, processingTask == nil else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            EngineLogStream.shared.append("[downloads] the game-install background window could not be scheduled: \(error.localizedDescription)", level: .warning)
        }
    }

    private func expireProcessingTask() {
        EngineLogStream.shared.append("[downloads] the background processing window expired; keep Windoz open to finish the game install.", level: .warning)
        finishProcessingTask(success: false)
        endBackgroundTask()
    }

    private func finishProcessingTask(success: Bool) {
        processingTask?.setTaskCompleted(success: success)
        processingTask = nil
    }
}
