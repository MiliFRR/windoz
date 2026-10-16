import SwiftUI

@main
struct WindozApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .preferredColorScheme(.dark)
            .tint(Color(red: 0.30, green: 0.56, blue: 1.0))
        }
    }
}
