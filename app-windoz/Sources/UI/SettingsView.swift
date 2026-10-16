import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var engine: WindozEngine
    @ObservedObject private var installer = RuntimeInstaller.shared
    @ObservedObject private var log = EngineLogStream.shared
    @ObservedObject private var controller = ControllerManager.shared

    @AppStorage("windoz.jitMethod") private var jitMethodRaw =
        (AppEnvironment.availableJITMethods.first ?? .stikDebug).rawValue
    @State private var confirmDelete = false
    @State private var confirmRepair = false
    @State private var coreMessage: String?

    var body: some View {
        ZStack {
            ConsoleBackground()
            List {
                engineSection
                jitSection
                prefixSection
                runtimeSection
                downloadSection
                diagnosticsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .onAppear {
            engine.refreshStatus()
            installer.refresh(prefix: engine.prefix)
        }
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

    private var engineSection: some View {
        Section("Engine") {
            statusRow("Just-in-time code", engine.status.jit)
            statusRow("Increased memory", engine.status.memoryEntitlement)
            LabeledContent("Free storage",
                           value: ByteCountFormatter.string(fromByteCount: engine.status.freeStorageBytes, countStyle: .file))
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
        }
    }

    private var jitSection: some View {
        Section("JIT") {
            // Only offer a choice when there genuinely is one: this build has no
            // helper extension in the bundle, so the StikDebug app is the route.
            if AppEnvironment.availableJITMethods.count > 1 {
                Picker("Method", selection: $jitMethodRaw) {
                    ForEach(AppEnvironment.availableJITMethods) { method in
                        Text(method.title).tag(method.rawValue)
                    }
                }
            } else if let only = AppEnvironment.availableJITMethods.first {
                LabeledContent("Method", value: only.title)
            }
            Text(AppEnvironment.jitSituation)
                .font(.caption).foregroundStyle(.secondary)
            if !engine.status.jit.isReady {
                Button("Enable JIT with StikDebug") {
                    if let url = JITManager.stikDebugEnableURL() { UIApplication.shared.open(url) }
                }
            }
            if JITManager.builtInHelperUsable {
                Text("Windoz's bundled helper can also be used on a normal sideload.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
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
        Section("Windows runtimes") {
            ForEach(RuntimeComponent.allCases) { component in
                HStack {
                    VStack(alignment: .leading) {
                        Text(component.title).font(.subheadline)
                        Text(component.detail).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    runtimeBadge(component)
                }
                if !(installer.states[component]?.isSatisfied ?? false), component.downloadURL != nil {
                    Button("Download official installer") { _ = installer.download(component) }
                        .font(.footnote)
                }
            }
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

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "0.2.0")
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

    private func runtimeBadge(_ component: RuntimeComponent) -> some View {
        Group {
            switch installer.states[component] ?? .unknown {
            case .present: Text("Installed").foregroundStyle(Theme.ok)
            case .missing: Text("Missing").foregroundStyle(Theme.warn)
            case .staged, .downloading: Text("Staged").foregroundStyle(Theme.accent)
            case .failed: Text("Problem").foregroundStyle(Theme.bad)
            case .unknown: Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { coreMessage = error.localizedDescription }
    }
}

/// The engine log, with an export action.
struct LogView: View {
    @ObservedObject private var log = EngineLogStream.shared

    var body: some View {
        List {
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
                Text("Microsoft Windows runtime files are downloaded on-device from Microsoft's own servers; Windoz does not redistribute them.")
            }
            .font(.footnote)
            .padding(18)
        }
        .navigationTitle("Licenses")
    }
}
