import SwiftUI
import UIKit

/// Cover art for a game. Falls back to a generated gradient tile with the
/// title's initials so the shelf never shows an empty grey box.
struct CoverArtView: View {
    let title: String
    var imagePath: String?
    var corner: CGFloat = 14

    var body: some View {
        ZStack {
            if let image = loadImage() {
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
    }

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    private func loadImage() -> UIImage? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        return UIImage(contentsOfFile: imagePath)
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
