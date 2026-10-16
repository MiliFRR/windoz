import SwiftUI

/// The console shell. Four destinations, dark by default, controller-friendly.
struct ConsoleRootView: View {
    @EnvironmentObject private var engine: WindozEngine

    private enum Tab: Hashable { case home, library, downloads, settings }

    @State private var tab: Tab = .home
    @State private var showSetup = false
    @AppStorage("windoz.didSetup") private var didSetup = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.library)

            NavigationStack { DownloadsView() }
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .tag(Tab.downloads)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) {
            if !engine.status.jit.isReady, !showSetup {
                jitBanner
            }
        }
        .task {
            engine.refreshStatus()
            if !didSetup { showSetup = true }
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
    }

    private var jitBanner: some View {
        Button {
            tab = .settings
            showSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(AppEnvironment.isLiveContainer
                     ? "JIT is off — in LiveContainer turn on Launch with JIT, then StikDebug. Tap to set it up."
                     : "JIT is off — games can't run yet. Tap to set it up.")
                    .font(.footnote.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.warn)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }
}
