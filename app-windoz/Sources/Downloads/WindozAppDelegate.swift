import UIKit

/// The small amount of UIKit lifecycle the background download queue needs.
///
/// iOS relaunches an app in the background to deliver the tail of a background
/// `URLSession` transfer. It calls this method before the SwiftUI scene exists,
/// so the handler is kept here and released by
/// `DownloadManager.urlSessionDidFinishEvents`.
@MainActor
final class WindozAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // BGTaskScheduler wants every identifier registered before launch
        // finishes. `register()` is idempotent; SwiftUI's app init calls it too.
        GameDownloadBackground.shared.register()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        // Hold the handler before creating the manager: iOS starts delivering
        // the waiting delegate events as soon as this method returns.
        WindozAppDelegate.backgroundCompletionHandler = completionHandler
        // The manager restores its queue from disk itself; creating it here
        // makes sure the background session has a delegate before iOS delivers
        // the waiting events.
        AppContainer.bootstrap()
        DownloadManager.shared.restore()
    }
}
