import SwiftUI

// MARK: - Model

enum TouchControlKind: String, Codable, CaseIterable, Identifiable {
    case button
    case dpad
    case stick

    var id: String { rawValue }
    var title: String {
        switch self {
        case .button: return "Button"
        case .dpad: return "D-pad"
        case .stick: return "Stick"
        }
    }
    var systemImage: String {
        switch self {
        case .button: return "circle"
        case .dpad: return "plus"
        case .stick: return "smallcircle.filled.circle"
        }
    }
}

struct TouchControl: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: TouchControlKind = .button
    var label: String = "A"
    /// Position as a fraction of the screen (0…1), so a layout adapts to any device.
    var x: Double = 0.5
    var y: Double = 0.5
    /// Diameter as a fraction of the screen's smaller side.
    var size: Double = 0.14
}

struct TouchLayout: Codable, Equatable {
    var controls: [TouchControl] = TouchLayout.default.controls

    static let `default` = TouchLayout(controls: [
        TouchControl(kind: .stick, label: "Move", x: 0.16, y: 0.80, size: 0.24),
        TouchControl(kind: .button, label: "A", x: 0.90, y: 0.82, size: 0.14),
        TouchControl(kind: .button, label: "B", x: 0.76, y: 0.90, size: 0.14),
        TouchControl(kind: .button, label: "X", x: 0.82, y: 0.66, size: 0.13),
        TouchControl(kind: .button, label: "Y", x: 0.68, y: 0.76, size: 0.13),
    ])
}

/// Persists one layout per game. Layouts live in Documents as JSON.
final class TouchLayoutStore: ObservableObject {
    static let shared = TouchLayoutStore()

    @Published private(set) var layouts: [String: TouchLayout] = [:]

    private let url = URL.documentsDirectory.appendingPathComponent("windoz-touch-layouts.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: TouchLayout].self, from: data) {
            layouts = decoded
        }
    }

    func layout(for gameID: UUID) -> TouchLayout {
        layouts[gameID.uuidString] ?? .default
    }

    func save(_ layout: TouchLayout, for gameID: UUID) {
        layouts[gameID.uuidString] = layout
        persist()
    }

    func reset(for gameID: UUID) {
        layouts.removeValue(forKey: gameID.uuidString)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(layouts) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Editor

/// The touch overlay editor. Drag controls to reposition them; add and remove
/// them; the result is saved per game. This is the same layout the in-session
/// overlay will render once the session host is ported.
struct TouchOverlayEditor: View {
    let gameID: UUID
    let gameTitle: String

    @State private var layout: TouchLayout
    @State private var selected: UUID?
    @State private var saved = false

    init(gameID: UUID, gameTitle: String) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        _layout = State(initialValue: TouchLayoutStore.shared.layout(for: gameID))
    }

    var body: some View {
        ZStack {
            ConsoleBackground()
            VStack(spacing: 12) {
                canvas
                controlBar
            }
            .padding(16)
        }
        .navigationTitle("Touch controls")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(layout == TouchLayoutStore.shared.layout(for: gameID))
            }
        }
        .overlay(alignment: .bottom) {
            if saved {
                Text("Saved for \(gameTitle)")
                    .font(.footnote)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
                Text("Drag a control to move it. Tap to select.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
                    .allowsHitTesting(false)
                    .opacity(layout.controls.isEmpty ? 1 : 0)

                ForEach($layout.controls) { $control in
                    controlView($control, in: geo.size)
                }
            }
        }
    }

    private func controlView(_ control: Binding<TouchControl>, in size: CGSize) -> some View {
        let c = control.wrappedValue
        let diameter = c.size * min(size.width, size.height)
        return ZStack {
            Circle()
                .fill(selected == c.id ? Theme.accent.opacity(0.85) : Color.white.opacity(0.18))
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
            Text(c.label)
                .font(.system(size: max(10, diameter * 0.28), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .position(x: c.x * size.width, y: c.y * size.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    selected = c.id
                    control.wrappedValue.x = min(max(value.location.x / size.width, 0.04), 0.96)
                    control.wrappedValue.y = min(max(value.location.y / size.height, 0.04), 0.96)
                }
                .onEnded { _ in }
        )
        .onTapGesture { selected = c.id }
        .accessibilityLabel("\(c.kind.title) \(c.label)")
    }

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { add(.button) } label: { barLabel("Add button", "plus.circle") }
                Button { add(.dpad) } label: { barLabel("Add D-pad", "plus") }
                Button { add(.stick) } label: { barLabel("Add stick", "smallcircle.filled.circle") }
                if let selected {
                    Button(role: .destructive) { remove(selected) } label: {
                        barLabel("Remove", "trash")
                    }
                }
                Button { layout = .default; selected = nil } label: { barLabel("Reset", "arrow.counterclockwise") }
            }
        }
    }

    private func barLabel(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func add(_ kind: TouchControlKind) {
        let control = TouchControl(kind: kind,
                                   label: kind == .button ? "A" : kind.title,
                                   x: 0.5, y: 0.5, size: kind == .stick ? 0.24 : 0.14)
        layout.controls.append(control)
        selected = control.id
    }

    private func remove(_ id: UUID) {
        layout.controls.removeAll { $0.id == id }
        selected = nil
    }

    private func save() {
        TouchLayoutStore.shared.save(layout, for: gameID)
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { saved = false }
        }
    }
}
