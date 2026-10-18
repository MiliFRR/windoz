import SwiftUI
import UIKit

/// First-run wizard and the Setup screen. It checks JIT, the increased-memory
/// entitlement, free storage and the missing Windows runtimes, in plain language,
/// with one-tap fixes where a fix exists.
struct SetupWizardView: View {
    @EnvironmentObject private var engine: WindozEngine
    @ObservedObject private var installer = RuntimeInstaller.shared
    @ObservedObject private var jit = JITCoordinator.shared

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
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    switch step {
                    case 0: jitStep
                    case 1: memoryStep
                    case 2: runtimeStep
                    default: readyStep
                    }

                    navigation
                }
                .padding(Metrics.pagePadding)
            }
        }
        .navigationTitle("Setup")
        .sheet(isPresented: $jit.showSetup) {
            JITSetupView().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
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
            if AppEnvironment.isLiveContainer {
                NavigationLink {
                    LiveContainerView()
                } label: {
                    Label("LiveContainer setup", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if !engine.status.jit.isReady {
                Button {
                    jit.enable { _ in }
                } label: {
                    Label(jit.resolvedMethod == .builtIn ? "Enable JIT (built-in helper)" : "Enable JIT with StikDebug",
                          systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                Button {
                    jit.showSetup = true
                } label: {
                    Label("JIT setup", systemImage: "bolt.badge.clock")
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
                    if AppEnvironment.isLiveContainer {
                        Text("LiveContainer cannot grant the increased-memory entitlement. Large games may be killed; that is a host limit, not a Windoz bug.")
                            .font(.caption)
                            .foregroundStyle(Theme.warn.opacity(0.9))
                    }
                }
            }
        }
    }

    private var runtimeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let problem = installer.manifestProblem {
                Text(problem).font(.caption).foregroundStyle(Theme.bad)
            }
            ForEach(installer.specs) { spec in
                GlassCard {
                    RuntimeRowView(spec: spec)
                }
            }
            if let runtimeMessage {
                Text(runtimeMessage).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
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
}
