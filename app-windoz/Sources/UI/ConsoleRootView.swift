import SwiftUI

/// The app shell: four standard tabs over a NavigationStack each.
struct ConsoleRootView: View {
    @EnvironmentObject private var engine: WindozEngine
    @EnvironmentObject private var library: GameLibrary
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var registry = StoreRegistry.shared

    private enum Tab: Hashable { case home, library, downloads, settings }

    @State private var tab: Tab = .home
    @State private var showSetup = false
    @AppStorage("windoz.didSetup") private var didSetup = false

    /// The session screen follows the engine: it appears when the engine hands
    /// a game to it and disappears when the session ends.
    private var sessionBinding: Binding<InstalledGame?> {
        Binding(
            get: { engine.sessionGame },
            set: { if $0 == nil { engine.detachSession(reason: "The session screen was dismissed.") } })
    }

    var body: some View {
        let _ = BootTrace.once("console body")
        TabView(selection: $tab) {
            let _ = BootTrace.once("tab: building home")
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            let _ = BootTrace.once("tab: building library")
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                .badge(library.games.count)
                .tag(Tab.library)

            let _ = BootTrace.once("tab: building downloads")
            NavigationStack { DownloadsView() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .badge(activeDownloadCount)
                .tag(Tab.downloads)

            let _ = BootTrace.once("tab: building settings")
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) {
            // Only a probe answer of "off" shows the banner: while the status
            // is still being checked, nothing is claimed (2026-10-17 device
            // report: the banner claimed "JIT is off" while the engine-core
            // test held the probe queue).
            if case .unavailable = engine.status.jit, !showSetup {
                jitBanner
            }
        }
        .task {
            BootTrace.mark("console task: first frame; refreshing status")
            engine.refreshStatus()
            if !didSetup { showSetup = true }
            BootTrace.mark("console task done; boot complete")
        }
        .onChange(of: tab) { _, new in
            BootTrace.mark("tab selected: \(new)")
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                SetupWizardView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { didSetup = true; showSetup = false }
                        }
                    }
            }
            .environmentObject(engine)
        }
        .fullScreenCover(item: sessionBinding) { game in
            GameSessionView(game: game)
                .environmentObject(engine)
                .interactiveDismissDisabled(true)
        }
    }

    /// The live count behind the Downloads tab badge: items still moving in
    /// the Windoz queue, Steam installs (queued or active), and Epic's one.
    private var activeDownloadCount: Int {
        var count = downloads.items.filter { !$0.state.isTerminal }.count
        for download in registry.steam.downloads.values {
            if case .failed = download.state { continue }
            count += 1
        }
        if registry.epic.download != nil { count += 1 }
        return count
    }

    private var jitBanner: some View {
        Button {
            tab = .settings
            showSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(AppEnvironment.isLiveContainer
                     ? "JIT is off — tap to set it up."
                     : "JIT is off — tap to set it up.")
                    .font(.footnote.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.warn.opacity(0.25)))
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }
}
