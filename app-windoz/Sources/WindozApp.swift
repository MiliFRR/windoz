import SwiftUI

@main
struct WindozApp: App {
    @StateObject private var engine = WindozEngine.shared
    @StateObject private var library = GameLibrary.shared

    init() {
        // Launch breadcrumbs stay in the app (they cost nothing): LiveContainer
        // gives no crash logs for guests, so if a launch crash ever returns,
        // Documents/windoz-boot.log names the exact step it died on.
        BootTrace.mark("---- session start (app init) ----")
        AppContainer.bootstrap()
        DozDock.Offline.begin()
        DownloadManager.shared.restore()
        BootTrace.mark("app init done")
    }

    var body: some Scene {
        WindowGroup {
            ConsoleRootView()
                .environmentObject(engine)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
