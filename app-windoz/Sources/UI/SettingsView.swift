import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var engine: WindozEngine
    @ObservedObject private var installer = RuntimeInstaller.shared
    @ObservedObject private var steamStore = StoreRegistry.shared.steam
    @ObservedObject private var epicStore = StoreRegistry.shared.epic

    /// One source of truth for the JIT method and state: the setup screen and
    /// the pre-launch auto-attempt read the same coordinator.
    @ObservedObject private var jit = JITCoordinator.shared

    @State private var swap = MadeiraConfig.readSwap()
    @State private var swapMessage: String?
    @State private var swapError: String?
    @AppStorage(SessionPreferences.pointerKey) private var pointerRaw = PointerMode.touchscreen.rawValue
    @AppStorage(SessionPreferences.ecoKey) private var ecoDefault = false
    @AppStorage(SessionPreferences.sensitivityKey)
    private var pointerSensitivity = SessionPreferences.defaultSensitivity

    var body: some View {
        List {
            engineSection
            memorySection
            sessionSection
            accountsSection
            if AppEnvironment.isLiveContainer {
                liveContainerSection
            }
            Section {
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
            }
            aboutSection
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $jit.showSetup) {
            JITSetupView().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .onAppear {
            engine.refreshStatus()
            installer.refresh(prefix: engine.prefix)
            swap = MadeiraConfig.readSwap()
        }
    }

    // MARK: - Sections

    private var engineSection: some View {
        Section("Engine") {
            statusRow("Just-in-time code", engine.status.jit)
            statusRow("Increased memory", engine.status.memoryEntitlement)
            LabeledContent("Free storage",
                           value: ByteCountFormatter.string(fromByteCount: engine.status.freeStorageBytes, countStyle: .file))
            if engine.status.memoryFootprintBytes > 0 {
                LabeledContent("Memory in use",
                               value: ByteCountFormatter.string(fromByteCount: engine.status.memoryFootprintBytes, countStyle: .memory))
            }
            if let expiry = engine.status.signingExpiresAt {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                LabeledContent("Signing expires") {
                    Text(expiry, style: .date)
                        .foregroundStyle(days < 3 ? Theme.bad : Theme.warn)
                }
                if days <= 3 {
                    Text("Re-sign Windoz within \(max(days, 0)) day(s) or it will stop launching.")
                        .font(.caption).foregroundStyle(Theme.bad)
                }
            }
            Button("Check again") { engine.refreshStatus() }

            // JIT setup, folded in so there is one engine story on one screen.
            Picker("JIT method", selection: $jit.method) {
                ForEach(JITMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            if jit.method == .automatic {
                Text(jit.automaticDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if jit.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(jit.status ?? "Working…")
                }
            } else if let error = jit.error {
                Text(error).font(.caption).foregroundStyle(Theme.bad)
            } else if let status = jit.status {
                Text(status).font(.caption).foregroundStyle(Theme.ok)
            } else {
                Text(AppEnvironment.jitSituation)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("JIT setup") { jit.showSetup = true }
            if case .unavailable = engine.status.jit, !jit.busy {
                Button("Enable JIT") { jit.enable { _ in } }
            }
        }
    }

    /// Swap memory. The values and the cfg keys are Madeira's own Memory &
    /// sync options; the engine side has read them since the pinned fork and
    /// Windoz only needed to write the file.
    private var memorySection: some View {
        Section {
            Picker("Swap memory", selection: swapSizeBinding) {
                ForEach(MadeiraConfig.Swap.sizes, id: \.self) { size in
                    Text(MadeiraConfig.Swap.title(for: size)).tag(size)
                }
            }
            if swap.sizeMB > 0 {
                Picker("Coverage", selection: swapCoverageBinding) {
                    ForEach(MadeiraConfig.Coverage.allCases) { coverage in
                        Text(coverage.title).tag(coverage)
                    }
                }
                Text(swap.coverage.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let swapError {
                Text(swapError).font(.caption).foregroundStyle(Theme.bad)
            } else if let swapMessage {
                Text(swapMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("A file-backed tier for game memory: 1, 2 or 4 GB of the app's temporary storage, off by default. Windoz saves the choice app-side, writes a per-launch cfg under its writable storage root and passes it to the engine as MADEIRA_CFG_GAME, so it works even when Documents is read-only. It is not iOS virtual memory and cannot exceed free storage.")
        }
    }

    /// How a finger drives the guest pointer and the engine's low-power thread
    /// class. Both are session-wide; a game's own layout and resolution stay on
    /// its page.
    private var sessionSection: some View {
        Section {
            Picker("Pointer", selection: pointerBinding) {
                ForEach(PointerMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text(pointerMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Pointer sensitivity",
                           value: String(format: "%.2f×", pointerSensitivity))
            Slider(value: $pointerSensitivity,
                   in: SessionPreferences.sensitivityRange,
                   step: 0.05) {
                Text("Pointer sensitivity")
            }
            Text("Scales one-finger trackpad movement and the controller's right-stick mouse. The session settings panel has the same control.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Eco mode for new sessions", isOn: ecoBinding)
            Text("Runs the game's threads at the engine's low-power QoS class. Loading is slower, but the phone keeps more of its thermal budget for gameplay. The session menu can change it live; this is the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Session")
        }
    }

    private var pointerMode: PointerMode {
        PointerMode(rawValue: pointerRaw) ?? .touchscreen
    }

    private var pointerBinding: Binding<String> {
        Binding(get: { pointerRaw }, set: { value in
            pointerRaw = value
            SessionPreferences.pointerMode = PointerMode(rawValue: value) ?? .touchscreen
        })
    }

    private var ecoBinding: Binding<Bool> {
        Binding(get: { ecoDefault }, set: { value in
            ecoDefault = value
            SessionPreferences.ecoMode = value
            if engine.phase.isActive { engine.setEco(value) }
        })
    }

    private var swapSizeBinding: Binding<Int> {
        Binding(get: { swap.sizeMB }, set: { size in
            var updated = swap
            updated.sizeMB = size
            saveSwap(updated)
        })
    }

    private var swapCoverageBinding: Binding<MadeiraConfig.Coverage> {
        Binding(get: { swap.coverage }, set: { coverage in
            var updated = swap
            updated.coverage = coverage
            saveSwap(updated)
        })
    }

    private func saveSwap(_ updated: MadeiraConfig.Swap) {
        do {
            try MadeiraConfig.writeSwap(updated)
            swap = MadeiraConfig.readSwap()
            swapError = nil
            swapMessage = swap.isOff
                ? "Swap memory is off."
                : "Saved. The tier is armed the next time a game starts."
        } catch {
            swap = MadeiraConfig.readSwap()
            swapMessage = nil
            swapError = error.localizedDescription
        }
    }

    /// Who is signed in, and the way out. Sign-out also stays tucked under
    /// the ellipsis menus on the store rows; this is the one place that lists
    /// every session, including Epic's launcher session.
    private var accountsSection: some View {
        Section("Accounts") {
            LabeledContent("Steam", value: accountValue(steamStore.authState))
            if steamStore.authState.isSignedIn {
                Button("Sign out of Steam", role: .destructive) { steamStore.signOut() }
            }
            LabeledContent("Epic", value: accountValue(epicStore.authState))
            LabeledContent("Epic launcher session",
                           value: epicStore.launcherSignedIn
                               ? (EpicLauncherSignIn.accountName ?? "Connected")
                               : "Not connected")
            if epicStore.authState.isSignedIn || epicStore.launcherSignedIn {
                Button("Sign out of Epic", role: .destructive) { epicStore.signOut() }
            }
            Text("Sign-ins live in this device's Keychain — no passwords, only tokens.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var liveContainerSection: some View {
        Section("LiveContainer") {
            NavigationLink("Setup for LiveContainer") {
                LiveContainerView().environmentObject(engine)
            }
            Text("JIT, extra RAM, Live Activities and background tasks follow LiveContainer's host entitlements. Windoz does not pretend those guest features exist.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: AppContainer.displayVersion)
            LabeledContent("Engine", value: "Wine ARM64EC · FEX · DXMT · D3D12")
            LabeledContent("Install", value: AppEnvironment.installKind)
            Link("Source code (GPL-3.0-or-later)", destination: URL(string: "https://github.com/MiliFRR/windoz")!)
            NavigationLink("Licenses") { LicensesView() }
        }
    }

    // MARK: - Helpers

    @ViewBuilder private func statusRow(_ name: String, _ health: EngineHealth) -> some View {
        HStack {
            Text(name)
            Spacer()
            switch health {
            case .ready: Text("Ready").foregroundStyle(Theme.ok)
            case .checking: Text("Checking…").foregroundStyle(Theme.warn)
            case .unknown: Text("—").foregroundStyle(.secondary)
            case .unavailable(let why): Text("Not active").foregroundStyle(Theme.bad).help(why)
            }
        }
    }

    private func accountValue(_ state: StoreAuthState) -> String {
        switch state {
        case .signedOut: return "Signed out"
        case .signingIn(let what): return what
        case .signedIn(let who): return who
        case .error(let why): return why
        }
    }
}

/// The rarely-needed half of Settings: the Windows environment, runtime
/// staging, the diagnostics tools and the log. Keeps the main screen short.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var engine: WindozEngine
    @ObservedObject private var installer = RuntimeInstaller.shared
    @ObservedObject private var log = EngineLogStream.shared
    @ObservedObject private var controller = ControllerManager.shared

    @State private var confirmDelete = false
    @State private var confirmRepair = false
    @State private var coreMessage: String?

    var body: some View {
        List {
            quitSection
            prefixSection
            runtimeSection
            downloadSection
            diagnosticsSection
        }
        .navigationTitle("Advanced")
        .onAppear { installer.refresh(prefix: engine.prefix) }
        .confirmationDialog("Delete the Windows environment?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { perform { try engine.deletePrefix() } }
        } message: {
            Text("Installed games outside the environment are kept, but their saved data inside it is removed.")
        }
        .confirmationDialog("Repair the Windows environment?",
                            isPresented: $confirmRepair, titleVisibility: .visible) {
            Button("Repair", role: .destructive) { perform { try engine.repairPrefix() } }
        } message: {
            Text("A clean Windows environment is extracted. Games you installed stay where they are.")
        }
    }

    // MARK: - Sections

    private var quitSection: some View {
        Section {
            Button("Quit Windoz now", role: .destructive) {
                AppContainer.quitNow(reason: "quitting from Settings → Advanced")
            }
            if engine.engineWedged {
                Text("The engine is stuck from the last launch attempt, so this app run cannot start a game again. Quitting is the repair.")
                    .font(.caption).foregroundStyle(Theme.warn)
            } else if engine.sessionsThisRun > 0 {
                Text("A game session already ran in this app run; Wine hosts one per process.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        } header: {
            Text("App run")
        } footer: {
            Text("Wine hosts one game session per app process, and a stalled start-up holds the engine's locks. Quitting closes Windoz on purpose so it can be opened fresh — nothing is lost: downloads resume and the library stays.")
        }
    }

    private var prefixSection: some View {
        Section("Windows environment") {
            LabeledContent("State", value: engine.prefixIsReady ? "Ready" : "Not created")
            Button("Create / seed") { perform { try engine.createPrefix() } }
            Button("Repair") { confirmRepair = true }
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
    }

    private var runtimeSection: some View {
        Section {
            if let problem = installer.manifestProblem {
                Text(problem).font(.caption).foregroundStyle(Theme.bad)
            }
            ForEach(installer.specs) { spec in
                RuntimeRowView(spec: spec)
            }
        } header: {
            Text("Windows runtimes")
        } footer: {
            Text("Windoz downloads only from the vendor's own links and verifies what it gets: a SHA-256 pinned in the build, or the first download's hash frozen in the prefix. A changed file is refused, never installed silently.")
        }
    }

    private var downloadSection: some View {
        Section("Downloads") {
            Toggle("Wi-Fi only", isOn: Binding(
                get: { DownloadManager.shared.wifiOnly },
                set: { DownloadManager.shared.setWifiOnly($0) }))
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button("Check Windows-prefix write access") {
                coreMessage = PrefixHealth.checkAndRepair(steamApps: SteamStore.steamApps)
            }
            Button("Start engine core (test)") {
                coreMessage = "Starting…"
                Task {
                    do {
                        try await engine.startEngineCore()
                        coreMessage = "Engine core started successfully."
                    } catch {
                        coreMessage = error.localizedDescription
                    }
                }
            }
            if let coreMessage {
                Text(coreMessage).font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink {
                LogView()
            } label: {
                LabeledContent("Log", value: "\(log.lines.count) lines")
            }
            LabeledContent("Controller", value: controller.connectedName ?? "None connected")
        }
    }

    // MARK: - Helpers

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { coreMessage = error.localizedDescription }
    }
}

/// The engine log, the on-disk copies, and the export actions.
struct LogView: View {
    @ObservedObject private var log = EngineLogStream.shared

    var body: some View {
        List {
            Section("On this device") {
                let file = EngineLogFile.fileURL
                if FileManager.default.fileExists(atPath: file.path) {
                    Text(file.path).font(.caption2).foregroundStyle(.secondary)
                    ShareLink(item: file) { Label("Share the Windoz log file", systemImage: "square.and.arrow.up") }
                } else {
                    Text("The on-disk log has not been opened; the in-memory log below still works.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let wine = EngineLogFile.engineLogURL, FileManager.default.fileExists(atPath: wine.path) {
                    Text("Wine & guest output: \(wine.path)").font(.caption2).foregroundStyle(.secondary)
                    ShareLink(item: wine) { Label("Share the Wine log", systemImage: "square.and.arrow.up") }
                }
            }
            ForEach(log.lines.reversed()) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text).font(.system(.caption, design: .monospaced))
                    Text(line.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: log.exportText()) { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

/// Licence notices, as the GPL requires.
struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Windoz is licensed GPL-3.0-or-later. Its complete source is at https://github.com/MiliFRR/windoz, so any IPA you receive can be rebuilt from it.")
                Text("Windoz uses the Wine (ARM64EC), FEX-Emu, DXMT and native-D3D12 engine forks. Their notices and the full licence texts are bundled in the app's licenses folder.")
                Text("Windoz's JIT setup is ported from Madeira (GPL-3.0-or-later with its exception) and bundles StikJIT (MPL-2.0) and idevice (MIT). The full texts ship in the app's Legal folder with THIRD-PARTY-NOTICES.md.")
                Text("Microsoft Windows runtime files are downloaded on-device from Microsoft's own servers; Windoz does not redistribute them.")
            }
            .font(.footnote)
            .padding(Metrics.pagePadding)
        }
        .navigationTitle("Licenses")
    }
}
