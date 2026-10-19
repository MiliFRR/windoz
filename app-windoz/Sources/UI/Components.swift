import SwiftUI
import UIKit

/// Cover art for a game. Falls back to a generated tile with the title's
/// initials so the shelf never shows an empty grey box.
///
/// The image is decoded off the main thread through `CoverArtCache` (idle-heat
/// fix): re-rendering the shelf no longer re-reads every tile from disk.
struct CoverArtView: View {
    let title: String
    var imagePath: String?
    var corner: CGFloat = Metrics.tileCorner
    /// Longest-edge decode bound. Tiles are ~124 pt wide at 3x, so 512 px is
    /// already above their rendered size; decoding at 1024 wasted memory and
    /// jetsam headroom for no visible gain.
    var maxPixel: CGFloat = 512

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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: imagePath) {
            guard let imagePath, !imagePath.isEmpty else {
                image = nil
                return
            }
            image = await CoverArtCache.image(at: imagePath, maxPixel: maxPixel)
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
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(monogram)
                .font(.system(size: size * (monogram.count > 1 ? 0.34 : 0.44),
                              weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
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

/// A small badge (store, anti-cheat, compatibility). Plain and compact — no
/// capsule outline, no glow.
struct Badge: View {
    let text: String
    var systemImage: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.weight(.semibold)) }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .foregroundStyle(tint)
    }
}

struct HealthDot: View {
    let health: EngineHealth
    var body: some View {
        Circle()
            .fill(Theme.healthColor(health))
            .frame(width: 8, height: 8)
    }
}

/// The app's primary action: a standard filled iOS button with the app's one
/// gradient, not a console bar.
struct PrimaryButton: View {
    let title: String
    var systemImage: String = "play.fill"
    var busy: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title).font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .fill(Theme.actionGradient))
            .shadow(color: Theme.accentDeep.opacity(0.28), radius: 8, y: 3)
            .opacity(enabled && !busy ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .accessibilityLabel(title)
    }
}

/// A small selectable pill, used for the Library's filter row: flat fill when
/// idle, accent-tinted when chosen.
struct Chip: View {
    let title: String
    var selected: Bool

    var body: some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected
                    ? Theme.accent.opacity(0.22)
                    : Color(uiColor: .secondarySystemFill)))
            .foregroundStyle(selected ? Theme.accent : .primary)
    }
}

/// A section title in the normal iOS sense: sentence case, headline weight.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled value row used in Settings and the game page.
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .overlay(Divider(), alignment: .bottom)
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
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}

/// The game page's hero art, decoded off the main thread through the same
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
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    var tint: Color {
        switch state {
        case .pending: return .secondary
        case .running: return Theme.accent
        case .done: return Theme.ok
        case .failed: return Theme.bad
        case .skipped: return .secondary
        }
    }
}
