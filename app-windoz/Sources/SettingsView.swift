import SwiftUI

struct SettingsView: View {
    @StateObject private var engine = WindozEngine.shared

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.07), .black],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                List {
                    Section("ENGINE") {
                        statusRow("JIT", engine.status.jit)
                        statusRow("Memory+", engine.status.memoryEntitlement)
                        Button("Re-check") { engine.refreshStatus() }
                            .foregroundStyle(.blue)
                    }
                    Section("STORAGE") {
                        HStack {
                            Text("Free space")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: engine.status.freeStorageBytes,
                                                           countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("STORES") {
                        HStack {
                            Image(systemName: "steam.symbols") ?? Image(systemName: "gamecontroller")
                            Text("Steam")
                            Spacer()
                            Text("coming").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Epic, GOG, Rockstar, EA")
                            Spacer()
                            Text("planned").foregroundStyle(.secondary)
                        }
                    }
                    Section("ABOUT") {
                        HStack { Text("Version"); Spacer(); Text("0.1.0 (build #26)").foregroundStyle(.secondary) }
                        HStack { Text("Engine"); Spacer(); Text("Wine 11 ARM64EC · FEX · DXMT").foregroundStyle(.secondary) }
                        NavigationLink("Licenses") {
                            ScrollView {
                                Text("Windoz is GPL-3.0-or-later. Source: https://github.com/MiliFRR/windoz — includes Wine (LGPL-2.1), FEX-Emu and DXMT fork changes (GPL-3.0-or-later), and other components listed in the bundled licenses folder.")
                                    .font(.footnote)
                                    .padding(16)
                            }
                            .navigationTitle("Licenses")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .onAppear { engine.refreshStatus() }
        }
    }

    @ViewBuilder
    private func statusRow(_ name: String, _ health: EngineHealth) -> some View {
        HStack {
            Text(name)
            Spacer()
            switch health {
            case .ready: Text("Ready").foregroundStyle(.green)
            case .checking: Text("Checking…").foregroundStyle(.yellow)
            case .unknown: Text("—").foregroundStyle(.secondary)
            case .unavailable(let why): Text("Unavailable").foregroundStyle(.red)
            }
        }
    }
}
