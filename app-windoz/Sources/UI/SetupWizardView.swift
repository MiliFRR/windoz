import SwiftUI
import UIKit

/// First-run wizard and the Setup screen. It checks JIT, the increased-memory
/// entitlement, free storage and the missing Windows runtimes, in plain language,
/// with one-tap fixes where a fix exists.
struct SetupWizardView: View {
    @EnvironmentObject private var engine: WindozEngine
    @ObservedObject private var installer = RuntimeInstaller.shared

    @State private var step = 0
    @State private var runtimeMessage: String?

    private let stepTitles = ["Just-in-time code", "Memory & storage", "Windows runtimes", "Ready"]

    var body: some View {
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ProgressView(value: Double(step + 1), total: Double(stepTitles.count))
                        .tint(Theme.accent)
                    Text(stepTitles[step])
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    switch step {
                    case 0: jitStep
                    case 1: memoryStep
                    case 2: runtimeStep
                    default: readyStep
                    }

                    navigation
                }
                .padding(20)
            }
        }
        .navigationTitle("Setup")
        .onAppear {
            engine.refreshStatus()
            installer.refresh(prefix: engine.prefix)
        }
    }

    // MARK: - Steps

    private var jitStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusLine(health: engine.status.jit, text: jitSummary)
            Text(AppEnvironment.jitSituation)
                .font(.footnote).foregroundStyle(.white.opacity(0.6))
            if !engine.status.jit.isReady {
                Button {
                    openStikDebug()
                } label: {
                    Label("Enable JIT with StikDebug", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if let why = engine.status.jit.reason {
                Text(why).font(.caption).foregroundStyle(Theme.bad.opacity(0.9))
            }
        }
    }

    private var jitSummary: String {
        if engine.status.jit.isReady { return "JIT is on. Translated games will run." }
        return "JIT is off. Games cannot translate x86-64 code until it is on."
    }

    private var memoryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusLine(health: engine.status.memoryEntitlement,
                       text: engine.status.memoryEntitlement.isReady
                             ? "The increased-memory limit is active."
                             : "The increased-memory limit is not active.")
            if let reason = engine.status.memoryEntitlement.reason {
                Text(reason).font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Free storage",
                            value: ByteCountFormatter.string(fromByteCount: engine.status.freeStorageBytes, countStyle: .file))
                    InfoRow(label: "Plan for", value: "Games + prefix, ~3 GB to start")
                    InfoRow(label: "Install type", value: AppEnvironment.installKind)
                }
            }
        }
    }

    private var runtimeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(RuntimeComponent.allCases) { component in
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(component.title).font(.headline).foregroundStyle(.white)
                            Spacer()
                            runtimeBadge(component)
                        }
                        Text(component.detail)
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                        if !(installer.states[component]?.isSatisfied ?? false) {
                            Button("Download the official installer") {
                                runtimeMessage = installer.download(component)
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            if let runtimeMessage {
                Text(runtimeMessage).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func runtimeBadge(_ component: RuntimeComponent) -> some View {
        switch installer.states[component] ?? .unknown {
        case .present: return Text("Installed").font(.caption).foregroundStyle(Theme.ok)
        case .missing: return Text("Missing").font(.caption).foregroundStyle(Theme.warn)
        case .staged: return Text("Staged").font(.caption).foregroundStyle(Theme.accent)
        case .downloading: return Text("Downloading").font(.caption).foregroundStyle(Theme.accent)
        case .failed: return Text("Problem").font(.caption).foregroundStyle(Theme.bad)
        case .unknown: return Text("—").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusLine(health: engine.status.jit, text: engine.status.jit.isReady ? "JIT ready" : "JIT still off — games will not run")
            StatusLine(health: engine.status.memoryEntitlement, text: "Memory entitlement checked")
            Text("You can change any of this later in Settings. On a free Apple ID the signing expires weekly — Windoz warns you before then.")
                .font(.footnote).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var navigation: some View {
        HStack {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if step < stepTitles.count - 1 {
                Button("Next") { withAnimation { step += 1 } }
                    .font(.headline).foregroundStyle(Theme.accent)
            }
        }
        .padding(.top, 8)
    }

    private func openStikDebug() {
        if let url = JITManager.stikDebugEnableURL() {
            UIApplication.shared.open(url)
        }
    }
}
