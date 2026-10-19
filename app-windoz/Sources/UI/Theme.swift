import SwiftUI
import UIKit

/// Windoz's look. 0.6.0 still carried the old "10-foot console" language —
/// gradient wallpaper, glowing wordmark, oversized tiles, tracked uppercase
/// labels — which the owner kept reading as an iPad UI enlarged onto a phone.
/// This is a normal iPhone app now: system backgrounds, system type, compact
/// grouped cards, one accent colour, no glow.
enum Theme {
    static let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let accentWarm = Color(red: 0.55, green: 0.35, blue: 0.95)
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let warn = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let bad = Color(red: 1.00, green: 0.27, blue: 0.23)

    /// The one gradient in the app: primary actions (Play, Add) fill with the
    /// accent sweeping into indigo. Everything else stays flat system colour.
    static let accentDeep = Color(red: 0.36, green: 0.33, blue: 0.92)
    static let actionGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Kept for the few views that need a fallback fill. System colours adapt
    /// to light/dark and match the rest of iOS.
    static let background = Color(uiColor: .systemGroupedBackground)
    static let heroGradient = LinearGradient(
        colors: [Color(uiColor: .tertiarySystemFill), Color(uiColor: .secondarySystemGroupedBackground)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tileGradient = LinearGradient(
        colors: [Color(uiColor: .tertiarySystemFill), Color(uiColor: .secondarySystemFill)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func healthColor(_ health: EngineHealth) -> Color {
        switch health {
        case .ready: return ok
        case .checking: return warn
        case .unavailable: return bad
        case .unknown: return .secondary
        }
    }
}

/// Phone-first metrics. Everything is sized for a 6-inch phone held in one
/// hand; nothing is sized for a TV or an iPad.
enum Metrics {
    static let pagePadding: CGFloat = 16
    static let pageSpacing: CGFloat = 18
    static let cardCorner: CGFloat = 12
    static let tileCorner: CGFloat = 8
    /// "Continue playing" covers.
    static let heroTileWidth: CGFloat = 124
    static let heroTileHeight: CGFloat = 166
    /// The Home tab's full-width featured card.
    static let featuredHeight: CGFloat = 172
    /// Shelf / grid covers.
    static let shelfTileWidth: CGFloat = 96
    static let shelfTileHeight: CGFloat = 128
    /// The game page's compact header cover.
    static let bannerHeight: CGFloat = 118
}

/// A grouped card, the way an inset-grouped iOS list draws one: a flat system
/// fill, a 12 pt radius, no glass, no stroke, no glow.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
    }
}

/// The app-wide background: the standard iOS grouped background.
struct ConsoleBackground: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
    }
}
