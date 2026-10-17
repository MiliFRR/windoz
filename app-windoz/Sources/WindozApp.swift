import SwiftUI

@main
struct WindozApp: App {
    @StateObject private var engine = WindozEngine.shared
    @StateObject private var library = GameLibrary.shared

    init() {
        // Diagnostic build (2026-10-17): every launch step leaves a breadcrumb
        // in Documents/windoz-boot.log, and the root gate shows the previous
        // session's tail before any store code can run.
        BootTrace.mark("---- session start (app init) ----")
        AppContainer.bootstrap()
        DownloadManager.shared.restore()
        BootTrace.mark("app init done")
    }

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environmentObject(engine)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Diagnostic-build root: the boot gate first — it renders before any store
/// or engine code runs, so it survives a launch crash and can show the log of
/// the session that died. Continue swaps in the real console.
private struct RootGateView: View {
    @State private var proceed = false

    var body: some View {
        if proceed {
            ConsoleRootView()
        } else {
            BootGateView(onContinue: {
                BootTrace.mark("gate: continue tapped")
                proceed = true
            })
        }
    }
}
