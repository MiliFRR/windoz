import SwiftUI

struct GameDetailView: View {
    let game: LocalGame
    @StateObject private var engine = WindozEngine.shared
    @State private var launching = false
    @State private var engineMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.07), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(colors: [Color(red: 0.15, green: 0.30, blue: 0.55),
                                                Color(red: 0.03, green: 0.05, blue: 0.12)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(.white.opacity(0.08))
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.title)
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                            Text(game.exePath.components(separatedBy: "/").last ?? "")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(16)
                    }

                    Button {
                        launch()
                    } label: {
                        HStack {
                            if launching {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("PLAY")
                                .font(.system(.headline, design: .rounded))
                                .tracking(2)
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.30, blue: 0.65),
                                                          Color(red: 0.04, green: 0.10, blue: 0.30)],
                                                 startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain)
                    .disabled(launching)

                    honestState

                    VStack(alignment: .leading, spacing: 8) {
                        Text("SETTINGS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.45))
                            .tracking(3)
                        settingRow("Scaling", "100 %")
                        settingRow("FPS cap", "Unlimited")
                        settingRow("Upscaling", "MetalFX — when supported")
                        settingRow("Graphics backend", "D3D11 via DXMT · D3D12 native")
                    }
                    .opacity(0.85)
                }
                .padding(18)
            }
        }
        .navigationTitle("")
        .onAppear { engine.refreshStatus() }
        .alert("Engine", isPresented: .constant(engineMessage != nil)) {
            Button("OK", role: .cancel) { engineMessage = nil }
        } message: {
            Text(engineMessage ?? "")
        }
    }

    /// Honest per the ground rules: this build starts the engine core
    /// (prefix + wineserver + FEX) so the chain is verified on-device, and
    /// says plainly that full session hosting (rendering + input) is still
    /// being ported behind the engine API.
    private func launch() {
        launching = true
        Task {
            do {
                try await engine.startEngineCore()
                engineMessage = EngineError.sessionHostingNotPorted.errorDescription
            } catch {
                engineMessage = error.localizedDescription
            }
            launching = false
        }
    }

    private var honestState: some View {
        Label("Session hosting (game rendering + input) is being ported into Windoz; this build verifies the engine core on your device.",
              systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.5))
    }

    private func settingRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text(value).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 6)
        .overlay(Divider().background(.white.opacity(0.08)), alignment: .bottom)
    }
}
