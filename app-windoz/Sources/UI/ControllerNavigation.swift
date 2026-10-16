import Foundation
import GameController
import UIKit
import AudioToolbox

enum ConsoleButton {
    case up, down, left, right
    case select      // A / Cross
    case back        // B / Circle
    case options     // Y / Triangle
    case menu        // Start / Options
}

/// Turns a physical controller into the console's input. Screens install a
/// handler while they are on screen, so the D-pad and sticks move the current
/// selection and the face buttons act on it. Haptics and a quiet click accompany
/// every move, honoring Reduce Motion / Reduce Sound where relevant.
final class ControllerManager: ObservableObject {
    static let shared = ControllerManager()

    @Published private(set) var connectedName: String?

    /// Set by the on-screen view; cleared on disappear.
    var onButton: ((ConsoleButton) -> Void)?

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private var lastStickDirection: ConsoleButton?
    private var heldButtons: Set<String> = []
    private var soundEnabled = true

    private init() {
        impact.prepare()
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.configure(GCController.controllers())
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.configure(GCController.controllers())
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        configure(GCController.controllers())
    }

    private func configure(_ controllers: [GCController]) {
        connectedName = controllers.first?.vendorName ?? nil
        for controller in controllers {
            if let pad = controller.extendedGamepad { wire(pad) }
            else if let micro = controller.microGamepad { wire(micro) }
        }
    }

    private func wire(_ pad: GCExtendedGamepad) {
        pad.dpad.up.pressedChangedHandler = buttonHandler("up", .up)
        pad.dpad.down.pressedChangedHandler = buttonHandler("down", .down)
        pad.dpad.left.pressedChangedHandler = buttonHandler("left", .left)
        pad.dpad.right.pressedChangedHandler = buttonHandler("right", .right)
        pad.buttonA.pressedChangedHandler = buttonHandler("a", .select)
        pad.buttonB.pressedChangedHandler = buttonHandler("b", .back)
        pad.buttonY.pressedChangedHandler = buttonHandler("y", .options)
        pad.buttonMenu.pressedChangedHandler = buttonHandler("menu", .menu)
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.stick(x: x, y: y)
        }
    }

    private func wire(_ micro: GCMicroGamepad) {
        micro.dpad.up.pressedChangedHandler = buttonHandler("up", .up)
        micro.dpad.down.pressedChangedHandler = buttonHandler("down", .down)
        micro.dpad.left.pressedChangedHandler = buttonHandler("left", .left)
        micro.dpad.right.pressedChangedHandler = buttonHandler("right", .right)
        micro.buttonA.pressedChangedHandler = buttonHandler("a", .select)
        micro.buttonX.pressedChangedHandler = buttonHandler("x", .back)
    }

    private func buttonHandler(_ key: String, _ button: ConsoleButton)
        -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            guard let self else { return }
            if pressed {
                guard !self.heldButtons.contains(key) else { return }
                self.heldButtons.insert(key)
                self.emit(button)
            } else {
                self.heldButtons.remove(key)
            }
        }
    }

    private func stick(x: Float, y: Float) {
        let deadzone: Float = 0.55
        var direction: ConsoleButton?
        if abs(x) > abs(y) {
            if x > deadzone { direction = .right } else if x < -deadzone { direction = .left }
        } else {
            if y > deadzone { direction = .up } else if y < -deadzone { direction = .down }
        }
        guard direction != lastStickDirection else { return }
        lastStickDirection = direction
        if let direction { emit(direction) }
    }

    private func emit(_ button: ConsoleButton) {
        impact.impactOccurred()
        if soundEnabled { AudioServicesPlaySystemSound(1104) }
        onButton?(button)
    }

    func setSoundEnabled(_ enabled: Bool) { soundEnabled = enabled }
}

/// A tiny index-based focus model for row/carousel navigation. Screens own one
/// and let the controller move it.
final class ConsoleFocus: ObservableObject {
    @Published var index: Int = 0
    @Published var count: Int = 0

    func move(_ delta: Int) {
        guard count > 0 else { return }
        index = min(max(index + delta, 0), count - 1)
    }

    func reset() { index = min(index, max(count - 1, 0)) }
}
