// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
//
// Session-wide preferences that outlive one game: how a finger drives the
// pointer, and whether the engine should start guest threads in its low-power
// QoS class. They are app preferences, not per-game engine settings; the game
// page's own settings stay in GameSettings.
//
// PointerMode is the session's input contract:
//   touchscreen — the finger is the pointer (direct touch), as before;
//   trackpad    — relative movement with an owned cursor, like a laptop pad:
//                 drag to move, tap to click, two-finger drag to scroll and
//                 two-finger tap to right-click. The guest is sent Windows
//                 mouse input (winios_pointer), not touches.
enum PointerMode: String, CaseIterable, Identifiable, Codable {
    case touchscreen
    case trackpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .touchscreen: return "Touchscreen"
        case .trackpad: return "Trackpad"
        }
    }

    var shortTitle: String {
        switch self {
        case .touchscreen: return "Touchscreen"
        case .trackpad: return "Trackpad"
        }
    }

    var detail: String {
        switch self {
        case .touchscreen:
            return "The finger is the pointer: touching the game clicks where you touch and dragging drags there. It is direct, and the right choice for touch-first games."
        case .trackpad:
            return "The finger moves a pointer relative to its last position, like a laptop trackpad. Drag to move, tap to left-click, hold to drag, two-finger drag to scroll, two-finger tap to right-click. The pointer stays where you leave it."
        }
    }
}

enum SessionPreferences {
    static let pointerKey = "windoz.session.pointer"
    static let ecoKey = "windoz.session.eco"
    static let sensitivityKey = "windoz.session.trackpadSensitivity"

    /// Multiplier on the trackpad's finger-to-cursor travel and on the
    /// controller right stick's mouse speed. 1.3 is the 0.9.0 trackpad scale;
    /// the range reaches slow precision and fast full-screen movement.
    static let sensitivityRange = 0.35...3.0
    static let defaultSensitivity = 1.3

    static var trackpadSensitivity: Double {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: sensitivityKey) != nil else {
                return defaultSensitivity
            }
            let value = defaults.double(forKey: sensitivityKey)
            return min(max(value, sensitivityRange.lowerBound), sensitivityRange.upperBound)
        }
        set {
            let clamped = min(max(newValue, sensitivityRange.lowerBound), sensitivityRange.upperBound)
            UserDefaults.standard.set(clamped, forKey: sensitivityKey)
        }
    }

    static var pointerMode: PointerMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: pointerKey),
                  let mode = PointerMode(rawValue: raw) else { return .touchscreen }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: pointerKey) }
    }

    /// The engine's low-power thread class (`madeira_set_eco`). Off by default;
    /// the in-session menu can change it while a game runs, and the next
    /// session starts with whichever choice was last saved here.
    static var ecoMode: Bool {
        get { UserDefaults.standard.bool(forKey: ecoKey) }
        set { UserDefaults.standard.set(newValue, forKey: ecoKey) }
    }
}
