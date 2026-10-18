import SwiftUI

/// Windoz's look: dark by default, deep blue-black, cyan/violet accents, large
/// rounded "console" tiles. Deliberately original — no console vendor's assets
/// or trade dress.
enum Theme {
    static let accent = Color(red: 0.30, green: 0.56, blue: 1.00)
    static let accentWarm = Color(red: 0.62, green: 0.36, blue: 1.00)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.00, green: 0.78, blue: 0.30)
    static let bad = Color(red: 1.00, green: 0.42, blue: 0.42)

    static let background = LinearGradient(
        colors: [Color(red: 0.03, green: 0.04, blue: 0.09), .black],
        startPoint: .top, endPoint: .bottom)

    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.12, green: 0.22, blue: 0.48), Color(red: 0.03, green: 0.05, blue: 0.12)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let tileGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.14, blue: 0.28), Color(red: 0.04, green: 0.05, blue: 0.12)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let corner: CGFloat = 16

    static func healthColor(_ health: EngineHealth) -> Color {
        switch health {
        case .ready: return ok
        case .checking: return warn
        case .unavailable: return bad
        case .unknown: return .gray
        }
    }
}

/// Phone-first metrics. The 0.5.0 build used one fixed "10-foot console"
/// scale on every screen, which on a 6-inch phone read as a zoomed iPad UI
/// (owner report, 2026-10-18: "stuff is too big"). Screens now lay out from
/// these values and from adaptive containers, so nothing is sized for a TV.
enum Metrics {
    static let pagePadding: CGFloat = 16
    static let pageSpacing: CGFloat = 18
    static let cardCorner: CGFloat = 16
    static let tileCorner: CGFloat = 12
    static let heroTileWidth: CGFloat = 176
    static let heroTileHeight: CGFloat = 238
    static let shelfTileWidth: CGFloat = 112
    static let shelfTileHeight: CGFloat = 150
    static let bannerHeight: CGFloat = 200
}

/// A translucent card. Uses the system material so it adapts to Liquid Glass on
/// iOS 26 while still working on older SDKs.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        Group {
            if reduceTransparency {
                content.padding(padding).background(Color.black.opacity(0.85), in: shape)
            } else if #available(iOS 26.0, *) {
                content.padding(padding).glassEffect(.regular, in: shape)
            } else {
                content.padding(padding).background(.ultraThinMaterial, in: shape)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
    }
}

/// The app-wide background. Honors Reduce Transparency by falling back to a flat
/// color.
struct ConsoleBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color.black
            } else {
                ZStack {
                    Theme.background
                    RadialGradient(colors: [Theme.accent.opacity(0.18), .clear],
                                   center: .topLeading, startRadius: 40, endRadius: 520)
                    RadialGradient(colors: [Theme.accentWarm.opacity(0.14), .clear],
                                   center: .bottomTrailing, startRadius: 40, endRadius: 520)
                }
            }
        }
        .ignoresSafeArea()
    }
}
