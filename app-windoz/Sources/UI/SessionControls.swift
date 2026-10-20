// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
//
// The session's controls: the on-screen pad for the Xbox and PlayStation
// layouts, and how a physical controller reaches the guest. Reimplemented for
// Windoz from the pinned Madeira's behaviour (GamepadInput.swift and
// PadKeyboardMouse.swift are GPL-3.0-or-later with the Madeira Converter
// Exception); no Madeira app code is compiled in.

import Foundation
import UIKit
import GameController
import QuartzCore

// MARK: - The snapshot the guest reads

/// One sample of the session's virtual controller, in the field layout of the
/// engine's `struct winios_gamepad` (the transport owns the packet number).
struct SessionPadState: Equatable {
    var buttons: UInt16 = 0
    var lt: UInt8 = 0
    var rt: UInt8 = 0
    var lx: Int16 = 0
    var ly: Int16 = 0
    var rx: Int16 = 0
    var ry: Int16 = 0

    static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let v = max(-1, min(1, value))
        return Int16((v * (v < 0 ? 32768 : 32767)).rounded())
    }

    static func trigger(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((max(0, min(1, value)) * 255).rounded())
    }

    /// The same arbitration the fork uses: a physical stick outside its XInput
    /// dead zone wins; otherwise a deflected touch stick is used, so a resting
    /// touch stick never erases a small physical deflection.
    static func merge(physical p: SessionPadState, touch t: SessionPadState) -> SessionPadState {
        var result = p
        result.buttons |= t.buttons
        result.lt = max(p.lt, t.lt)
        result.rt = max(p.rt, t.rt)
        if magnitude(p.lx, p.ly) <= 7849 && (t.lx != 0 || t.ly != 0) {
            result.lx = t.lx; result.ly = t.ly
        }
        if magnitude(p.rx, p.ry) <= 7849 && (t.rx != 0 || t.ry != 0) {
            result.rx = t.rx; result.ry = t.ry
        }
        return result
    }

    private static func magnitude(_ x: Int16, _ y: Int16) -> Double {
        (Double(x) * Double(x) + Double(y) * Double(y)).squareRoot()
    }
}

/// XInput button bits, exactly the masks `winios_gamepad` carries.
enum SessionPadButton: UInt16 {
    case dpadUp = 0x0001
    case dpadDown = 0x0002
    case dpadLeft = 0x0004
    case dpadRight = 0x0008
    case menu = 0x0010
    case view = 0x0020
    case leftThumb = 0x0040
    case rightThumb = 0x0080
    case leftShoulder = 0x0100
    case rightShoulder = 0x0200
    case guide = 0x0400
    case a = 0x1000
    case b = 0x2000
    case x = 0x4000
    case y = 0x8000
}

// MARK: - The bridge

/// Owns the session's controller story:
///
/// - **Keyboard & mouse** (default): the on-screen pad is hidden, the guest
///   sees no virtual gamepad, and a connected physical controller becomes keys
///   and mouse motion through the built-in template (WASD on the left stick,
///   the mouse on the right stick, Space/Ctrl/E/R on the face buttons, the
///   triggers as the mouse buttons, the D-pad as the arrow keys, Start as
///   Escape, Select as Tab).
/// - **Xbox / PlayStation**: the guest sees one connected XInput pad in slot 0,
///   fed by the merged physical controller and on-screen pad.
///
/// Everything runs on the main thread; the C entry points are thread-safe by
/// contract, and every timer here is a main-run-loop timer.
final class SessionGamepad {
    static let shared = SessionGamepad()

    private(set) var layout: ControlLayout = .keyboardMouse
    private var active = false

    private var physicalPad: GCExtendedGamepad?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    private var touchState = SessionPadState()
    private var lastSample = 0.0
    private var disconnectSent = false

    // Keyboard-and-mouse state
    private var pressedActions: [String: KBMAction] = [:]
    private var leftDir = -1
    private var leftKeys: [Int32] = []
    private var mouseCarry = CGPoint.zero

    private init() {}

    // MARK: Lifecycle

    func activate(layout: ControlLayout) {
        guard !active else { setLayout(layout); return }
        active = true
        self.layout = layout
        lastSample = 0
        observe()
        attachController()
        startTimer()
        publish()
    }

    func deactivate() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        physicalPad?.valueChangedHandler = nil
        physicalPad = nil
        releaseKeyboardMouse()
        touchState = SessionPadState()
        disconnect()
    }

    /// Called when the in-session menu changes the layout. Takes effect at
    /// once: the pad appears/disappears and the physical controller switches
    /// between XInput and the keyboard-and-mouse translation.
    func setLayout(_ layout: ControlLayout) {
        guard self.layout != layout else { return }
        if self.layout == .keyboardMouse || layout == .keyboardMouse {
            releaseKeyboardMouse()
        }
        self.layout = layout
        touchState = SessionPadState()
        lastSample = 0
        disconnectSent = false
        publish()
    }

    /// The on-screen pad's current state; neutral when it is hidden.
    func setTouch(_ state: SessionPadState) {
        touchState = state
        publish()
    }

    /// The line the session menu shows: what the controller story is right now.
    var controllerSummary: String {
        if let name = physicalPad?.controller?.vendorName, !name.isEmpty { return name }
        return physicalPad == nil ? "No controller connected" : "Controller connected"
    }

    // MARK: Observers

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachController()
            self?.publish()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachController()
            self?.releaseKeyboardMouse()
            self?.publish()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // A delayed callout must not republish a held key once the app is
            // gone; the session's slot goes to rest.
            self?.releaseKeyboardMouse()
            self?.touchState = SessionPadState()
            self?.publish()
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.attachController()
            self?.publish()
        })
    }

    private func attachController() {
        let controller = GCController.controllers().first
        let pad = controller?.extendedGamepad
        if pad !== physicalPad {
            physicalPad?.valueChangedHandler = nil
            physicalPad = pad
            pad?.valueChangedHandler = { [weak self] _, _ in self?.publish() }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.publish() }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Sampling

    private func publish() {
        guard active else { return }
        let now = CACurrentMediaTime()
        let dt = lastSample == 0 ? 1.0 / 120.0 : min(now - lastSample, 0.25)
        lastSample = now

        var physical = SessionPadState()
        if let pad = physicalPad { physical = sample(pad) }

        guard layout.isGamepad else {
            feedKeyboardMouse(physical, dt: dt)
            disconnect()
            return
        }

        releaseKeyboardMouse()
        let merged = SessionPadState.merge(physical: physical, touch: touchState)
        var out = winios_gamepad()
        out.connected = 1
        out.buttons = merged.buttons
        out.left_trigger = merged.lt
        out.right_trigger = merged.rt
        out.lx = merged.lx
        out.ly = merged.ly
        out.rx = merged.rx
        out.ry = merged.ry
        disconnectSent = false
        winios_gamepad_set_state(0, &out)
    }

    private func disconnect() {
        guard !disconnectSent else { return }
        disconnectSent = true
        winios_gamepad_set_state(0, nil)
    }

    private func sample(_ pad: GCExtendedGamepad) -> SessionPadState {
        var state = SessionPadState()
        let buttons: [(GCControllerButtonInput?, UInt16)] = [
            (pad.dpad.up, SessionPadButton.dpadUp.rawValue), (pad.dpad.down, SessionPadButton.dpadDown.rawValue),
            (pad.dpad.left, SessionPadButton.dpadLeft.rawValue), (pad.dpad.right, SessionPadButton.dpadRight.rawValue),
            (pad.buttonMenu, SessionPadButton.menu.rawValue), (pad.buttonOptions, SessionPadButton.view.rawValue),
            (pad.leftThumbstickButton, SessionPadButton.leftThumb.rawValue),
            (pad.rightThumbstickButton, SessionPadButton.rightThumb.rawValue),
            (pad.leftShoulder, SessionPadButton.leftShoulder.rawValue),
            (pad.rightShoulder, SessionPadButton.rightShoulder.rawValue),
            (pad.buttonHome, SessionPadButton.guide.rawValue),
            (pad.buttonA, SessionPadButton.a.rawValue), (pad.buttonB, SessionPadButton.b.rawValue),
            (pad.buttonX, SessionPadButton.x.rawValue), (pad.buttonY, SessionPadButton.y.rawValue),
        ]
        for (button, mask) in buttons where button?.isPressed == true { state.buttons |= mask }
        state.lt = SessionPadState.trigger(Double(pad.leftTrigger.value))
        state.rt = SessionPadState.trigger(Double(pad.rightTrigger.value))
        state.lx = SessionPadState.axis(Double(pad.leftThumbstick.xAxis.value))
        state.ly = SessionPadState.axis(Double(pad.leftThumbstick.yAxis.value))
        state.rx = SessionPadState.axis(Double(pad.rightThumbstick.xAxis.value))
        state.ry = SessionPadState.axis(Double(pad.rightThumbstick.yAxis.value))
        return state
    }

    // MARK: Keyboard-and-mouse translation (the built-in template)

    private enum KBMAction {
        case key(Int32)
        case mouseLeft
        case mouseRight
    }

    private static let kbmButtons: [(String, UInt16)] = [
        ("D↑", SessionPadButton.dpadUp.rawValue), ("D↓", SessionPadButton.dpadDown.rawValue),
        ("D←", SessionPadButton.dpadLeft.rawValue), ("D→", SessionPadButton.dpadRight.rawValue),
        ("Menu", SessionPadButton.menu.rawValue), ("View", SessionPadButton.view.rawValue),
        ("L3", SessionPadButton.leftThumb.rawValue), ("R3", SessionPadButton.rightThumb.rawValue),
        ("LB", SessionPadButton.leftShoulder.rawValue), ("RB", SessionPadButton.rightShoulder.rawValue),
        ("A", SessionPadButton.a.rawValue), ("B", SessionPadButton.b.rawValue),
        ("X", SessionPadButton.x.rawValue), ("Y", SessionPadButton.y.rawValue),
    ]

    /// The template from the pinned PadKeyboardMouse: what a pad input means in
    /// a game with no controller support.
    private static let kbmTemplate: [String: KBMAction] = [
        "A": .key(0x20),          // Space
        "B": .key(0x11),          // Ctrl
        "X": .key(0x45),          // E
        "Y": .key(0x52),          // R
        "LB": .key(0x51),         // Q
        "RB": .key(0x46),         // F
        "LT": .mouseRight,
        "RT": .mouseLeft,
        "L3": .key(0x10),         // Shift
        "R3": .key(0x43),         // C
        "Menu": .key(0x1B),       // Escape
        "View": .key(0x09),       // Tab
        "D↑": .key(0x26), "D↓": .key(0x28), "D←": .key(0x25), "D→": .key(0x27),
    ]

    /// WASD, in the sector order up/right/down/left.
    private static let wasd: [Int32] = [0x57, 0x44, 0x53, 0x41]
    private static let triggerThreshold: UInt8 = 128
    private static let stickDeadzone = 0.35
    private static let mouseSpeed = 1500.0

    private func feedKeyboardMouse(_ state: SessionPadState, dt: Double) {
        var down: Set<String> = []
        for (name, mask) in Self.kbmButtons where state.buttons & mask != 0 { down.insert(name) }
        if state.lt >= Self.triggerThreshold { down.insert("LT") }
        if state.rt >= Self.triggerThreshold { down.insert("RT") }

        for name in pressedActions.keys where !down.contains(name) {
            if let action = pressedActions.removeValue(forKey: name) { apply(action, down: false) }
        }
        for name in down where pressedActions[name] == nil {
            if let action = Self.kbmTemplate[name] {
                pressedActions[name] = action
                apply(action, down: true)
            }
        }

        // Left stick → WASD, released and pressed per sector so a held
        // direction does not stutter while the thumb wanders inside one sector.
        let left = Self.sector(Double(state.lx) / 32767.0, Double(state.ly) / 32767.0)
        if left != leftDir {
            let old = Set(leftKeys), new = Set(Self.sectorKeys(left, Self.wasd))
            for vk in old.subtracting(new) { winios_post_key(vk, 0) }
            for vk in new.subtracting(old) { winios_post_key(vk, 1) }
            leftKeys = Array(new)
            leftDir = left
        }

        // Right stick → relative mouse motion. The guest's cursor is moved,
        // never warped, so this follows whatever pointer mode the session uses.
        let shaped = Self.shape(Double(state.rx) / 32767.0, Double(state.ry) / 32767.0)
        // The same persisted multiplier as the touch trackpad, so a player who
        // slows the pointer down gets the same slower right stick.
        let sensitivity = SessionPreferences.trackpadSensitivity
        let step = Self.mouseSpeed * sensitivity * min(dt, 1.0 / 15.0)
        let dx = shaped.x * step
        let dy = -shaped.y * step
        mouseCarry.x += dx
        mouseCarry.y += dy
        let ix = Int32(mouseCarry.x.rounded(.towardZero))
        let iy = Int32(mouseCarry.y.rounded(.towardZero))
        if ix != 0 || iy != 0 {
            winios_pointer(ix, iy, 0x0001, 0)   // MOUSEEVENTF_MOVE, relative
            mouseCarry.x -= CGFloat(ix)
            mouseCarry.y -= CGFloat(iy)
        }
    }

    private func apply(_ action: KBMAction, down: Bool) {
        switch action {
        case .key(let vk): winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft: winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)
        case .mouseRight: winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)
        }
    }

    /// Releases every key and mouse button this translation holds. Safe to
    /// call at any time; it is idempotent.
    private func releaseKeyboardMouse() {
        for (_, action) in pressedActions { apply(action, down: false) }
        pressedActions.removeAll()
        for vk in leftKeys { winios_post_key(vk, 0) }
        leftKeys.removeAll()
        leftDir = -1
        mouseCarry = .zero
    }

    /// 0 = up, clockwise in 45° steps; -1 inside the dead zone.
    static func sector(_ x: Double, _ y: Double) -> Int {
        guard (x * x + y * y).squareRoot() >= stickDeadzone else { return -1 }
        var angle = atan2(x, y) * 180 / .pi
        if angle < 0 { angle += 360 }
        return Int((angle + 22.5) / 45.0) % 8
    }

    static func sectorKeys(_ sector: Int, _ keys: [Int32]) -> [Int32] {
        switch sector {
        case 0: return [keys[0]]
        case 1: return [keys[0], keys[1]]
        case 2: return [keys[1]]
        case 3: return [keys[2], keys[1]]
        case 4: return [keys[2]]
        case 5: return [keys[2], keys[3]]
        case 6: return [keys[3]]
        case 7: return [keys[0], keys[3]]
        default: return []
        }
    }

    /// Radial dead zone with a squared response, so fine movements stay slow.
    private static func shape(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude >= 0.18 else { return (0, 0) }
        let t = min((magnitude - 0.18) / (1 - 0.18), 1)
        let scaled = (t * t) / magnitude
        return (x * scaled, y * scaled)
    }
}

// MARK: - The on-screen pad

/// The on-screen Xbox / PlayStation pad. Empty areas pass touches through to
/// the game; only the controls themselves take input.
final class SessionPadOverlayView: UIView {

    var layout: ControlLayout = .keyboardMouse {
        didSet {
            guard layout != oldValue else { return }
            applyLayoutStyle()
        }
    }

    private let leftStick = PadStickView(label: "L")
    private let rightStick = PadStickView(label: "R")
    private var dpad: [SessionPadButton: PadButtonView] = [:]
    private var faces: [SessionPadButton: PadButtonView] = [:]
    private var shoulders: [SessionPadButton: PadButtonView] = [:]
    private var menuButtons: [SessionPadButton: PadButtonView] = [:]

    private var buttons: UInt16 = 0
    private var lt: UInt8 = 0, rt: UInt8 = 0
    private var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Same contract as the HUD: only real controls take touches.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func build() {
        let dpadMasks: [(SessionPadButton, String)] = [
            (.dpadUp, "▲"), (.dpadDown, "▼"), (.dpadLeft, "◀"), (.dpadRight, "▶"),
        ]
        for (button, title) in dpadMasks {
            let view = PadButtonView(title: title, size: 44)
            view.onPress = { [weak self] down in self?.set(button, down: down) }
            dpad[button] = view
            addSubview(view)
        }
        for button in [SessionPadButton.a, .b, .x, .y] {
            let view = PadButtonView(title: "A", size: 48)
            view.onPress = { [weak self] down in self?.set(button, down: down) }
            faces[button] = view
            addSubview(view)
        }
        for (button, title) in [(SessionPadButton.leftShoulder, "LB"), (.rightShoulder, "RB"),
                                (.leftThumb, "LT"), (.rightThumb, "RT")] {
            let view = PadButtonView(title: title, size: 40)
            if button == .leftThumb || button == .rightThumb {
                view.onPress = { [weak self] down in self?.trigger(button == .leftThumb, down: down) }
            } else {
                view.onPress = { [weak self] down in self?.set(button, down: down) }
            }
            shoulders[button] = view
            addSubview(view)
        }
        for (button, title) in [(SessionPadButton.menu, "MENU"), (.view, "VIEW")] {
            let view = PadButtonView(title: title, size: 30)
            view.onPress = { [weak self] down in self?.set(button, down: down) }
            menuButtons[button] = view
            addSubview(view)
        }

        leftStick.onChange = { [weak self] x, y in
            self?.lx = SessionPadState.axis(x)
            self?.ly = SessionPadState.axis(y)
            self?.publish()
        }
        rightStick.onChange = { [weak self] x, y in
            self?.rx = SessionPadState.axis(x)
            self?.ry = SessionPadState.axis(y)
            self?.publish()
        }
        addSubview(leftStick)
        addSubview(rightStick)
    }

    private func applyLayoutStyle() {
        isHidden = !layout.isGamepad
        guard layout.isGamepad else {
            resetTouch()
            return
        }

        switch layout {
        case .xbox:
            setFace(.a, "A", UIColor(red: 0.30, green: 0.68, blue: 0.32, alpha: 0.65))
            setFace(.b, "B", UIColor(red: 0.85, green: 0.28, blue: 0.24, alpha: 0.65))
            setFace(.x, "X", UIColor(red: 0.22, green: 0.48, blue: 0.88, alpha: 0.65))
            setFace(.y, "Y", UIColor(red: 0.92, green: 0.75, blue: 0.18, alpha: 0.65))
            setShoulderTitles(["LB", "RB", "LT", "RT"])
            setMenuTitles(["MENU", "VIEW"])
        case .playStation:
            setFace(.a, "✕", UIColor.white.withAlphaComponent(0.22))
            setFace(.b, "○", UIColor.white.withAlphaComponent(0.22))
            setFace(.x, "□", UIColor.white.withAlphaComponent(0.22))
            setFace(.y, "△", UIColor.white.withAlphaComponent(0.22))
            setShoulderTitles(["L1", "R1", "L2", "R2"])
            setMenuTitles(["OPTIONS", "CREATE"])
        case .keyboardMouse:
            break
        }
        setNeedsLayout()
    }

    private func setFace(_ button: SessionPadButton, _ title: String, _ color: UIColor) {
        faces[button]?.setTitle(title, for: .normal)
        faces[button]?.baseColor = color
    }

    private func setShoulderTitles(_ titles: [String]) {
        let order: [SessionPadButton] = [.leftShoulder, .rightShoulder, .leftThumb, .rightThumb]
        for (index, title) in titles.enumerated() where index < order.count {
            shoulders[order[index]]?.setTitle(title, for: .normal)
        }
    }

    private func setMenuTitles(_ titles: [String]) {
        menuButtons[.menu]?.setTitle(titles.first, for: .normal)
        menuButtons[.view]?.setTitle(titles.last, for: .normal)
    }

    private func resetTouch() {
        buttons = 0; lt = 0; rt = 0
        lx = 0; ly = 0; rx = 0; ry = 0
        for view in dpad.values { view.setHeld(false) }
        for view in faces.values { view.setHeld(false) }
        for view in shoulders.values { view.setHeld(false) }
        leftStick.reset()
        rightStick.reset()
        publish()
    }

    private func set(_ button: SessionPadButton, down: Bool) {
        if down { buttons |= button.rawValue } else { buttons &= ~button.rawValue }
        publish()
    }

    private func trigger(_ left: Bool, down: Bool) {
        if left { lt = down ? 255 : 0 } else { rt = down ? 255 : 0 }
        publish()
    }

    private func publish() {
        SessionGamepad.shared.setTouch(SessionPadState(
            buttons: buttons, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry))
    }

    // MARK: Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let safe = safeAreaInsets
        let minSide = min(bounds.width, bounds.height)
        let stick = min(max(minSide * 0.30, 92), 148)
        let face = stick * 0.42
        let dpadSize = stick * 0.40
        let margin: CGFloat = 16
        let bottom = bounds.height - safe.bottom - margin

        leftStick.frame = CGRect(x: safe.left + margin, y: bottom - stick, width: stick, height: stick)

        let faceCenter = CGPoint(x: bounds.width - safe.right - margin - face * 1.5, y: bottom - face * 1.5)
        let faceRadius = face * 1.02
        place(faces[.a], at: CGPoint(x: faceCenter.x, y: faceCenter.y + faceRadius), size: face * 0.92)
        place(faces[.b], at: CGPoint(x: faceCenter.x + faceRadius, y: faceCenter.y), size: face * 0.92)
        place(faces[.x], at: CGPoint(x: faceCenter.x - faceRadius, y: faceCenter.y), size: face * 0.92)
        place(faces[.y], at: CGPoint(x: faceCenter.x, y: faceCenter.y - faceRadius), size: face * 0.92)

        let rightStickX = faceCenter.x - faceRadius - face * 0.6 - stick
        rightStick.frame = CGRect(x: rightStickX, y: bottom - stick, width: stick, height: stick)

        let dpadCenter = CGPoint(x: safe.left + margin + stick / 2, y: leftStick.frame.minY - dpadSize * 0.75)
        place(dpad[.dpadUp], at: CGPoint(x: dpadCenter.x, y: dpadCenter.y - dpadSize * 0.55), size: dpadSize * 0.55)
        place(dpad[.dpadDown], at: CGPoint(x: dpadCenter.x, y: dpadCenter.y + dpadSize * 0.55), size: dpadSize * 0.55)
        place(dpad[.dpadLeft], at: CGPoint(x: dpadCenter.x - dpadSize * 0.55, y: dpadCenter.y), size: dpadSize * 0.55)
        place(dpad[.dpadRight], at: CGPoint(x: dpadCenter.x + dpadSize * 0.55, y: dpadCenter.y), size: dpadSize * 0.55)

        let shoulderWidth = face * 1.5, shoulderHeight = face * 0.62
        shoulders[.leftShoulder]?.frame = CGRect(x: safe.left + margin, y: safe.top + margin,
                                                 width: shoulderWidth, height: shoulderHeight)
        shoulders[.leftThumb]?.frame = CGRect(x: safe.left + margin, y: safe.top + margin + shoulderHeight + 8,
                                              width: shoulderWidth, height: shoulderHeight)
        shoulders[.rightShoulder]?.frame = CGRect(x: bounds.width - safe.right - margin - shoulderWidth,
                                                  y: safe.top + margin, width: shoulderWidth, height: shoulderHeight)
        shoulders[.rightThumb]?.frame = CGRect(x: bounds.width - safe.right - margin - shoulderWidth,
                                               y: safe.top + margin + shoulderHeight + 8,
                                               width: shoulderWidth, height: shoulderHeight)

        let menuWidth: CGFloat = 74, menuHeight: CGFloat = 26
        menuButtons[.menu]?.frame = CGRect(x: bounds.midX - menuWidth - 6, y: bottom - menuHeight,
                                           width: menuWidth, height: menuHeight)
        menuButtons[.view]?.frame = CGRect(x: bounds.midX + 6, y: bottom - menuHeight,
                                           width: menuWidth, height: menuHeight)
    }

    private func place(_ view: PadButtonView?, at center: CGPoint, size: CGFloat) {
        view?.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        view?.layer.cornerRadius = size / 2
    }
}

// MARK: - The keyboard-and-mouse overlay

/// The default keyboard-and-mouse session controls: a thumb stick that emits
/// W/A/S/D (real key events, not a virtual pad), a wide Space bar along the
/// bottom, and Escape with Tab directly beneath it at the top left. Empty
/// areas pass through, so touch and the trackpad still reach the game.
final class SessionKeyboardMouseOverlayView: UIView {
    var layout: ControlLayout = .keyboardMouse {
        didSet {
            guard layout != oldValue else { return }
            isHidden = layout != .keyboardMouse
            if isHidden { releaseAllKeys() }
        }
    }

    private let stick = PadStickView(label: "WASD")
    private let esc = HUDKeyButton(label: "ESC", vk: 0x1B, height: 32, autoLayout: false)
    private let tab = HUDKeyButton(label: "TAB", vk: 0x09, height: 32, autoLayout: false)
    private let space: HUDKeyButton
    private var heldKeys: [Int32] = []
    private var heldSector = -1
    private static let wasd: [Int32] = [0x57, 0x44, 0x53, 0x41]

    override init(frame: CGRect) {
        space = HUDKeyButton(label: "SPACE", vk: 0x20, height: 46, autoLayout: false)
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isHidden = true

        stick.onChange = { [weak self] x, y in self?.steer(x: x, y: y) }
        addSubview(stick)
        addSubview(space)
        addSubview(esc)
        addSubview(tab)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseAllKeys() }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let safe = safeAreaInsets
        let margin: CGFloat = 16
        let minSide = min(bounds.width, bounds.height)
        let stickSize = min(max(minSide * 0.26, 88), 136)
        let bottom = bounds.height - safe.bottom - margin

        stick.frame = CGRect(x: safe.left + margin, y: bottom - stickSize,
                             width: stickSize, height: stickSize)

        let spaceWidth = min(max(bounds.width * 0.30, 132), 220)
        space.frame = CGRect(x: bounds.midX - spaceWidth / 2,
                             y: bottom - 46,
                             width: spaceWidth, height: 46)

        // Escape at the top left with Tab directly beneath it. The HUD's title
        // stack starts 56 points in, so the two never overlap.
        let top = safe.top + 8
        esc.frame = CGRect(x: safe.left + margin, y: top, width: 46, height: 32)
        tab.frame = CGRect(x: safe.left + margin, y: esc.frame.maxY + 6, width: 46, height: 32)
    }

    /// Stick → real W/A/S/D key events. Released and re-pressed per 45° sector,
    /// so a diagonal holds both keys and a thumb wandering inside one sector
    /// does not stutter.
    private func steer(x: Double, y: Double) {
        let sector = SessionGamepad.sector(x, y)
        guard sector != heldSector else { return }
        let old = Set(heldKeys)
        let new = Set(sector < 0 ? [] : SessionGamepad.sectorKeys(sector, Self.wasd))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        heldKeys = Array(new)
        heldSector = sector
    }

    func releaseAllKeys() {
        for vk in heldKeys { winios_post_key(vk, 0) }
        heldKeys.removeAll()
        heldSector = -1
        stick.reset()
        esc.releaseIfDown()
        tab.releaseIfDown()
        space.releaseIfDown()
    }
}

/// A translucent round control. Held state changes the fill; the title stays
/// white for both pad flavours.
final class PadButtonView: UIButton {
    var onPress: ((Bool) -> Void)?

    var baseColor: UIColor = UIColor.white.withAlphaComponent(0.12) {
        didSet { updateFill() }
    }

    /// Not `held`: UIButton already declares that name in this SDK.
    private var pressedDown = false

    init(title: String, size: CGFloat) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.6
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        backgroundColor = baseColor
        addTarget(self, action: #selector(down), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(up), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        accessibilityLabel = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func down() { setHeld(true) }
    @objc private func up() { setHeld(false) }

    func setHeld(_ value: Bool) {
        guard pressedDown != value else { return }
        pressedDown = value
        updateFill()
        onPress?(value)
    }

    private func updateFill() {
        backgroundColor = pressedDown ? UIColor.white.withAlphaComponent(0.42) : baseColor
    }
}

/// A draggable stick. Reports a clamped unit vector; the thumb follows the
/// finger inside the base circle.
final class PadStickView: UIView {
    var onChange: ((Double, Double) -> Void)?

    private let titleLabel = UILabel()
    private let thumb = UIView()
    private var activeTouch: UITouch?
    private var value = CGPoint.zero

    init(label: String) {
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        titleLabel.text = label
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)
        thumb.backgroundColor = UIColor.white.withAlphaComponent(0.30)
        thumb.layer.borderWidth = 1
        thumb.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        addSubview(thumb)
        layer.cornerRadius = 12
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        thumb.layer.cornerRadius = bounds.width * 0.19
        titleLabel.frame = bounds
        positionThumb()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        update(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        update(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        value = .zero
        positionThumb()
        onChange?(0, 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    func reset() {
        activeTouch = nil
        value = .zero
        positionThumb()
    }

    private func update(_ touch: UITouch) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width / 2 - 8, 1)
        let point = touch.location(in: self)
        var dx = (point.x - center.x) / radius
        var dy = (point.y - center.y) / radius
        let magnitude = (dx * dx + dy * dy).squareRoot()
        if magnitude > 1 { dx /= magnitude; dy /= magnitude }
        value = CGPoint(x: dx, y: dy)
        positionThumb()
        onChange?(Double(dx), Double(-dy))   // up is positive
    }

    private func positionThumb() {
        let radius = max(bounds.width / 2 - 8, 1)
        let size = bounds.width * 0.38
        thumb.frame = CGRect(x: bounds.midX + value.x * radius - size / 2,
                             y: bounds.midY + value.y * radius - size / 2,
                             width: size, height: size)
        thumb.layer.cornerRadius = size / 2
    }
}
