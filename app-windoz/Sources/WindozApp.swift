import SwiftUI

@main
struct WindozApp: App {
    @StateObject private var engine = WindozEngine.shared
    @StateObject private var library = GameLibrary.shared

    var body: some Scene {
        WindowGroup {
            ConsoleRootView()
                .environmentObject(engine)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
