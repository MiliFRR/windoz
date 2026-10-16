import SwiftUI
import UIKit
import Darwin

/// First-class LiveContainer setup. Guest entitlements, extensions and
/// SpringBoard registration never apply here, so the only working JIT path is
/// LiveContainer's own "Launch with JIT" plus StikDebug and the staged script.
struct LiveContainerView: View {
    @EnvironmentObject private var engine: WindozEngine
    @State private var shareScript = false
    @State private var stagedPath: String?

    var body: some View {
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Windoz is running inside LiveContainer.")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("That is supported. LiveContainer does not copy guest entitlements or start app extensions, so a few iOS features stay off on purpose.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Guest bundle", value: AppEnvironment.bundleIdentifier)
                            InfoRow(label: "JIT target", value: AppEnvironment.jitTargetBundleIdentifier)
                            InfoRow(label: "Process id", value: "\(getpid())")
                            InfoRow(label: "Home", value: AppContainer.home.path)
                            InfoRow(label: "Memory in use",
                                    value: ByteCountFormatter.string(fromByteCount: engine.status.memoryFootprintBytes, countStyle: .memory))
                        }
                    }

                    SectionHeader(title: "Enable JIT")
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            numbered("1", "In LiveContainer, hold Windoz → Settings → turn on Launch with JIT.")
                            numbered("2", "On iOS 26 (A15+ / M2+), set JIT launch Script to the file Windoz stages at Documents/LiveContainer/windoz-jit.js.")
                            numbered("3", "In LiveContainer Settings → JIT, pick StikDebug, or StikDebug (Another LiveContainer) if StikDebug itself is a guest.")
                            numbered("4", "Do not enable JIT on LiveContainer first. Run Windoz and let LiveContainer wait, then attach.")
                            numbered("5", "Windoz re-checks JIT every time you press Play.")
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            if let url = AppContainer.stageJITScript() {
                                stagedPath = url.path
                                shareScript = true
                            }
                        } label: {
                            Label("Share JIT script", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let url = JITManager.stikDebugEnableURL() {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Open StikDebug", systemImage: "bolt.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white)

                    if let stagedPath {
                        Text("Staged at \(stagedPath)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    SectionHeader(title: "What cannot work here")
                    ForEach(AppEnvironment.hostLimits) { limit in
                        GlassCard {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(limit.title).font(.headline).foregroundStyle(.white)
                                if let note = limit.state.note {
                                    Text(note).font(.footnote).foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
                    }

                    Text("Chromium store launchers (Steam, Epic, EA, Rockstar) are started only when a game needs them and closed afterwards. iPhone RAM is tight inside LiveContainer because the increased-memory entitlement is not on the host.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(20)
            }
        }
        .navigationTitle("LiveContainer")
        .onAppear { engine.refreshStatus() }
        .sheet(isPresented: $shareScript) {
            if let url = AppContainer.stageJITScript() {
                ActivityShareView(items: [url])
            }
        }
    }

    private func numbered(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
            Text(text).font(.footnote).foregroundStyle(.white.opacity(0.8))
        }
    }
}

struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
