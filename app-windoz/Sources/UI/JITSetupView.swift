// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Ported from Madeira's JITSetupView (GPL-3.0-or-later, Madeira Converter
// Exception). The local-network shortcut feature is not ported; everything
// else has the same flow with Windoz's names.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The JIT setup screen: method, pairing, the built-in helper's checks and
/// StikDebug's fallback. Also where a failed pre-launch auto-attempt sends the
/// user, so the exact missing piece is one tap away.
struct JITSetupView: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    private var pairingLabel: String {
        switch coordinator.pairingSource {
        case .onDevice: return "Paired in Windoz"
        case .imported: return "File imported"
        case nil: return "Not set up"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $coordinator.method) {
                        ForEach(JITMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    if coordinator.method == .automatic {
                        Text(coordinator.automaticDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("StikDebug",
                                   value: StikDebugApp.isInstalled ? "Installed" : "Not detected")
                    LabeledContent("Built-in helper",
                                   value: WindozBuiltInJIT.isAvailable ? "Available" : "Unavailable")
                } header: {
                    Text("JIT method")
                } footer: {
                    Text("Automatic uses StikDebug when it is installed. Windoz does not silently change methods after a failure.")
                }

                if coordinator.method != .stikDebug {
                    Section {
                        LabeledContent("Pairing", value: pairingLabel)
                        if OnDevicePairing.isSupported {
                            Button(coordinator.pairingSource == .onDevice ? "Pair in Windoz again" : "Pair in Windoz") {
                                pairing.start()
                            }
                            .disabled(pairing.active)
                            OnDevicePairingPanel()
                        }
                        Button("Import pairing file") { importing = true }
                        Link("How to create a pairing file",
                             destination: URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!)
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                    } header: {
                        Text("Built-in StikJIT")
                    } footer: {
                        Text(OnDevicePairing.isSupported
                             ? "Pair in Windoz or import a pairing file made on a computer, connect LocalDevVPN, then check setup. The pairing file is kept in this device's Keychain. (The built-in helper works outside LiveContainer only: app extensions never start inside it.)"
                             : "Import this device's pairing file, connect LocalDevVPN, then check setup. The pairing file is kept in this device's Keychain. Pairing in Windoz needs iOS 27 or later, and the built-in helper works outside LiveContainer only.")
                    }

                    Section {
                        Button("Check setup") { coordinator.prepareBuiltIn() }
                            .disabled(coordinator.busy || !coordinator.pairingImported)
                        Button("Enable JIT") { coordinator.enableBuiltIn() }
                            .disabled(coordinator.busy || !coordinator.pairingImported)
                        Button("Reset Developer Disk Image", role: .destructive) {
                            coordinator.resetDDI()
                        }.disabled(coordinator.busy)
                    }
                } else {
                    Section {
                        if StikDebugApp.isInstalled {
                            Button("Enable JIT with StikDebug") { coordinator.enable { _ in } }
                        } else {
                            Link("Install StikDebug",
                                 destination: URL(string: "https://github.com/StikDebug/StikDebug/releases/latest")!)
                        }
                    } footer: {
                        Text("StikDebug needs a pairing file and an active LocalDevVPN connection. Windoz sends its own script automatically.")
                    }
                }

                if coordinator.busy {
                    Section { HStack { ProgressView(); Text(coordinator.status ?? "Working…") } }
                } else if let error = coordinator.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        if let problem = coordinator.connectionProblem { jitConnectionActions(problem) }
                    }
                } else if let status = coordinator.status {
                    Section { Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let txm = coordinator.txmPresent {
                    Section { LabeledContent("TXM/SPTM", value: txm ? "Present" : "Not present") }
                }
            }
            .navigationTitle("JIT setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { coordinator.showSetup = false; dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.propertyList, .data]) { result in
            if case .success(let url) = result {
                coordinator.importPairingFile(url)
            } else if case .failure(let failure) = result {
                EngineLogStream.shared.append("[jit-built-in] pairing import failed: \(failure.localizedDescription)",
                                              level: .error)
            }
        }
        .onAppear { coordinator.refreshPairingStatus() }
    }
}

/// The fix a JIT connection problem offers: pair again (rejected pairing) and LocalDevVPN.
@MainActor func jitConnectionActions(_ problem: JITCoordinator.ConnectionProblem,
                                     retry: (() -> Void)? = nil,
                                     then dismiss: @escaping () -> Void = {}) -> some View {
    Group {
        if problem == .pairing {
            Button(OnDevicePairing.isSupported ? "Pair Again" : "Open JIT Setup") {
                dismiss()
                if OnDevicePairing.isSupported { OnDevicePairing.shared.start() }
                JITCoordinator.shared.showSetup = true
            }
        }
        Button(LocalDevVPN.actionTitle) { dismiss(); LocalDevVPN.open() }
    }
}
