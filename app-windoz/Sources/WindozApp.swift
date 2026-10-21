import SwiftUI

@main
struct WindozApp: App {
    @UIApplicationDelegateAdaptor(WindozAppDelegate.self) private var appDelegate
    @StateObject private var engine = WindozEngine.shared
    @StateObject private var library = GameLibrary.shared

    init() {
        // Launch breadcrumbs stay in the app (they cost nothing): LiveContainer
        // gives no crash logs for guests, so if a launch crash ever returns,
        // Documents/windoz-boot.log names the exact step it died on.
        BootTrace.mark("---- session start (app init) ----")
        AppContainer.bootstrap()
        EngineLogFile.shared.start()
        DozDock.Offline.begin()
        GameDownloadBackground.shared.register()
        DownloadManager.shared.restore()
        #if DEBUG
        IdleMonitor.shared.start()
        #endif
        BootTrace.mark("app init done")
    }

    var body: some Scene {
        WindowGroup {
            ConsoleRootView()
                .environmentObject(engine)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { url in
                    // LocalDevVPN returns through windoz://… after connecting
                    // (`scheme=windoz`); JIT setup re-checks the loopback so
                    // the screen shows the tunnel's real state.
                    if JITCoordinator.shared.handleOpenURL(url) { return }
                    EngineLogStream.shared.append("[app] opened \(url.scheme ?? "?")://")
                }
        }
    }
}
