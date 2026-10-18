import SwiftUI
import UIKit

/// Cover art for a game. Falls back to a generated gradient tile with the
/// title's initials so the shelf never shows an empty grey box.
///
/// The image is decoded off the main thread through `CoverArtCache` (idle-heat
/// fix): re-rendering the shelf no longer re-reads every tile from disk.
struct CoverArtView: View {
    let title: String
    var imagePath: String?
    var corner: CGFloat = 14

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.tileGradient
                Text(initials)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.10)))
        .task(id: imagePath) {
            guard let imagePath, !imagePath.isEmpty else {
                image = nil
                return
            }
            image = await CoverArtCache.image(at: imagePath)
        }
    }

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

/// A store's icon: a rounded monogram tile drawn in code — letters and
/// gradients only, no vendor asset files anywhere. The letter is the store's
/// own initial(s); the colours are Windoz's.
struct StoreIcon: View {
    let id: StoreID
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(monogram)
                .font(.system(size: size * (monogram.count > 1 ? 0.34 : 0.44),
                              weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(radius: 2)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(.white.opacity(0.12)))
        .accessibilityLabel(id.title)
    }

    private var monogram: String {
        switch id {
        case .local: return "L"
        case .steam: return "S"
        case .epic: return "E"
        case .gog: return "G"
        case .rockstar: return "R"
        case .ea: return "EA"
        }
    }

    private var palette: [Color] {
        switch id {
        case .local:
            return [Color(red: 0.32, green: 0.36, blue: 0.44), Color(red: 0.16, green: 0.18, blue: 0.24)]
        case .steam:
            return [Color(red: 0.16, green: 0.36, blue: 0.58), Color(red: 0.05, green: 0.12, blue: 0.24)]
        case .epic:
            return [Color(red: 0.22, green: 0.22, blue: 0.25), Color(red: 0.05, green: 0.05, blue: 0.07)]
        case .gog:
            return [Color(red: 0.45, green: 0.28, blue: 0.72), Color(red: 0.18, green: 0.09, blue: 0.34)]
        case .rockstar:
            return [Color(red: 0.85, green: 0.55, blue: 0.15), Color(red: 0.38, green: 0.20, blue: 0.05)]
        case .ea:
            return [Color(red: 0.78, green: 0.18, blue: 0.22), Color(red: 0.32, green: 0.05, blue: 0.08)]
        }
    }
}

/// A small capsule badge (store, anti-cheat, compatibility).
struct Badge: View {
    let text: String
    var systemImage: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.18)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
        .foregroundStyle(tint)
    }
}

struct HealthDot: View {
    let health: EngineHealth
    var body: some View {
        Circle()
            .fill(Theme.healthColor(health))
            .frame(width: 9, height: 9)
            .shadow(color: Theme.healthColor(health).opacity(0.7), radius: 4)
    }
}

/// The console's primary action button.
struct PrimaryButton: View {
    let title: String
    var systemImage: String = "play.fill"
    var busy: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .tracking(1.5)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.55)],
                                         startPoint: .leading, endPoint: .trailing)))
            .opacity(enabled && !busy ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .accessibilityLabel(title)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .tracking(3)
            .foregroundStyle(.white.opacity(0.45))
    }
}

/// A labelled value row used in Settings and the game page.
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .white.opacity(0.55)

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .overlay(Divider().overlay(.white.opacity(0.08)), alignment: .bottom)
    }
}

/// A compatibility / anti-cheat summary line with the right colour.
struct StatusLine: View {
    let health: EngineHealth
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            HealthDot(health: health)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 0)
        }
    }
}

/// The game page's hero banner — decoded off the main thread through the same
/// cache the tiles use, so opening a page never blocks on disk I/O.
struct HeroArtView: View {
    let path: String?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.heroGradient
            }
        }
        .task(id: path) {
            guard let path, !path.isEmpty else {
                image = nil
                return
            }
            image = await CoverArtCache.image(at: path, maxPixel: 1280)
        }
    }
}

/// The launch checklist's colours, in the app's theme. The model
/// (`LaunchStep`) stays SwiftUI-free; the mapping lives here.
extension LaunchStep {
    var symbol: String {
        switch state {
        case .pending: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    var tint: Color {
        switch state {
        case .pending: return .white.opacity(0.35)
        case .running: return Theme.accent
        case .done: return Theme.ok
        case .failed: return Theme.bad
        case .skipped: return .white.opacity(0.45)
        }
    }
}
