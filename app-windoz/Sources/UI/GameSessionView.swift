// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — the in-session host: the presenting Metal layer, touch and
// hardware-keyboard input, and the session overlay.
//
// The techniques here follow Madeira (willfaust/Madeira, GPL-3.0-or-later with
// the Madeira Converter Exception) and the device findings documented in its
// sources: the window-level CAMetalLayer host (on iOS 26 a SwiftUI-hosted
// layer is intermittently routed through a path where direct Metal presents
// are silently dropped — the screen freezes on stale content), the
// `displaySyncEnabled=false` present behaviour, the aspect-fit guest mapping
// and the UIKey → virtual-key table. Reimplemented for Windoz; no Madeira app
// code is compiled in — every engine entry point below arrives through the
// engine boundary's bridging header.

import SwiftUI
import UIKit
import QuartzCore
import Metal

// MARK: - The window-level Metal host

/// Raw UIView that owns the CAMetalLayer the guest's swapchain presents into.
/// It lives directly in the UIWindow — never in SwiftUI's hierarchy, for the
/// reason in the header comment — and it never takes touches; the session
/// view underneath handles input. One instance per process, because the
/// engine's display shim resolves every guest window to the layer it was
/// given once.
final class WindozMetalHostView: UIView {
    static let shared = WindozMetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false          // touches fall through to the session view
        backgroundColor = .black
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Present without the compositor's sync on this layer; the pinned
        // engine's own sources use this same private pair.
        let syncSelector = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSelector) {
            metalLayer.perform(syncSelector, with: NSNumber(value: false))
        }
        // Seed the drawable before any layout is known; the session view
        // replaces it on every layout pass.
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Match the layer's backing resolution to the frame it is presenting in.
    func applyDrawableSize(_ size: CGSize) {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(size.width * scale, 1),
                                         height: max(size.height * scale, 1))
    }
}

// MARK: - Guest surface layout

/// How the guest's virtual monitor is laid out on the device's screen, and how
/// a touch point maps back to guest pixels. Aspect-fit only in this build: the
/// guest keeps its aspect and is centred, the remaining strip stays black.
/// (The pinned engine's front end offers fit/fill/stretch modes; choosing
/// between them is a settings-round item, not invented here.)
enum SessionSurfaceLayout {
    static func fittingRect(guest: CGSize, in bounds: CGRect) -> CGRect {
        guard guest.width > 0, guest.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / guest.width, bounds.height / guest.height)
        let size = CGSize(width: guest.width * scale, height: guest.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func guestPoint(_ point: CGPoint, rect: CGRect, guest: CGSize) -> (x: Int32, y: Int32) {
        guard rect.width > 0, rect.height > 0, guest.width > 0, guest.height > 0 else { return (0, 0) }
        let nx = (point.x - rect.minX) / rect.width
        let ny = (point.y - rect.minY) / rect.height
        let x = Int32((nx * guest.width).rounded(.down))
        let y = Int32((ny * guest.height).rounded(.down))
        return (min(max(x, 0), Int32(guest.width) - 1),
                min(max(y, 0), Int32(guest.height) - 1))
    }
}

// MARK: - The touch/keyboard surface

/// The SwiftUI-hosted placeholder: transparent, receives every touch and key,
/// keeps the presentation layer's frame in step, and registers the layer with
/// the engine's display shim. The guest's frames themselves appear in
/// `WindozMetalHostView` above.
final class SessionSurfaceView: UIView {
    private static var layerRegistered = false

    private var primaryTouch: UITouch?
    private lazy var hud = SessionHUDView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    private var guestSize: CGSize {
        var w: Int32 = 0
        var h: Int32 = 0
        winios_screen_size(&w, &h)
        if w > 0, h > 0 { return CGSize(width: CGFloat(w), height: CGFloat(h)) }
        return CGSize(width: 1024, height: 768)   // engine default until it publishes a mode
    }

    private var gameRect: CGRect { SessionSurfaceLayout.fittingRect(guest: guestSize, in: bounds) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else {
            teardown()
            return
        }

        let host = WindozMetalHostView.shared
        if host.superview !== window {
            host.removeFromSuperview()
            window.addSubview(host)
        }
        host.isHidden = false
        attachHUD(to: window)
        applyLayout()

        // Register the layer exactly once per process, before the guest's
        // first swapchain — the engine's requirement, not an optimisation.
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
        }
        becomeFirstResponder()
        WindozEngine.shared.sessionSurfaceReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
        // The host re-adds itself on its own move events; the overlay is
        // pinned back to the top on every layout so it cannot fall under it.
        if let window, hud.superview === window {
            window.bringSubviewToFront(hud)
        }
    }

    private func applyLayout() {
        guard let window else { return }
        let host = WindozMetalHostView.shared
        let windowRect = convert(gameRect, to: window)
        host.frame = windowRect
        host.applyDrawableSize(windowRect.size)
    }

    private func attachHUD(to window: UIWindow) {
        if hud.superview !== window {
            hud.removeFromSuperview()
            window.addSubview(hud)
        }
        hud.frame = window.bounds
        hud.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hud.title = WindozEngine.shared.sessionGame?.title ?? "Session"
        hud.line = { WindozEngine.shared.sessionHUDLine }
        hud.launchState = {
            let engine = WindozEngine.shared
            guard case .starting = engine.phase, !engine.launchSteps.isEmpty else { return nil }
            return LaunchHUDState(steps: engine.launchSteps, elapsed: engine.sessionElapsed)
        }
    }

    private func teardown() {
        WindozMetalHostView.shared.isHidden = true
        hud.removeFromSuperview()
    }

    // MARK: Touch → guest (1:1, aspect-fit mapped)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard primaryTouch == nil, let touch = touches.first else { return }
        primaryTouch = touch
        let (x, y) = SessionSurfaceLayout.guestPoint(touch.location(in: self), rect: gameRect, guest: guestSize)
        winios_post_touch_down(x, y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        let (x, y) = SessionSurfaceLayout.guestPoint(touch.location(in: self), rect: gameRect, guest: guestSize)
        winios_post_touch_move(x, y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        let (x, y) = SessionSurfaceLayout.guestPoint(touch.location(in: self), rect: gameRect, guest: guestSize)
        winios_post_touch_up(x, y)
        primaryTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: Hardware keyboard → guest

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let vk = Self.virtualKey(for: press) {
                winios_post_key(vk, 1)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let vk = Self.virtualKey(for: press) {
                winios_post_key(vk, 0)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    /// UIKey → Windows virtual-key: special keys first, then the US-layout
    /// character table (which follows the engine source's table). Shift state
    /// is not synthesised — pairs like "1" and "!" share the physical key —
    /// which is fine for games that act on key codes.
    static func virtualKey(for press: UIPress) -> Int32? {
        guard let key = press.key else { return nil }
        switch key.keyCode {
        case .keyboardEscape: return 0x1B
        case .keyboardReturnOrEnter: return 0x0D
        case .keyboardTab: return 0x09
        case .keyboardSpacebar: return 0x20
        case .keyboardDeleteOrBackspace: return 0x08
        case .keyboardDeleteForward: return 0x2E
        case .keyboardLeftArrow: return 0x25
        case .keyboardUpArrow: return 0x26
        case .keyboardRightArrow: return 0x27
        case .keyboardDownArrow: return 0x28
        case .keyboardHome: return 0x24
        case .keyboardEnd: return 0x23
        case .keyboardPageUp: return 0x21
        case .keyboardPageDown: return 0x22
        default: break
        }
        return virtualKey(forCharacters: key.characters)
    }

    static func virtualKey(forCharacters characters: String) -> Int32? {
        guard let ch = characters.first else { return nil }
        if ch == "\n" || ch == "\r" { return 0x0D }
        if ch == "\t" { return 0x09 }
        if ch == " " { return 0x20 }
        if ch == "\u{1B}" { return 0x1B }
        if ch == "\u{8}" || ch == "\u{7F}" { return 0x08 }
        if ch.isLetter, let up = ch.uppercased().first?.asciiValue, up >= 0x41, up <= 0x5A {
            return Int32(up)                                   // VK_A..VK_Z
        }
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case 0x30...0x39: return Int32(a)                      // 0-9
        case 0x60: return 0xC0                                 // `
        case 0x2D: return 0xBD                                 // -
        case 0x3D: return 0xBB                                 // =
        case 0x5B: return 0xDB                                 // [
        case 0x5D: return 0xDD                                 // ]
        case 0x5C: return 0xDC                                 // backslash
        case 0x3B: return 0xBA                                 // ;
        case 0x27: return 0xDE                                 // '
        case 0x2C: return 0xBC                                 // ,
        case 0x2E: return 0xBE                                 // .
        case 0x2F: return 0xBF                                 // /
        // Shifted symbols map to their physical key's VK.
        case 0x21: return 0x31                                 // !
        case 0x40: return 0x32                                 // @
        case 0x23: return 0x33                                 // #
        case 0x24: return 0x34                                 // $
        case 0x25: return 0x35                                 // %
        case 0x5E: return 0x36                                 // ^
        case 0x26: return 0x37                                 // &
        case 0x2A: return 0x38                                 // *
        case 0x28: return 0x39                                 // (
        case 0x29: return 0x30                                 // )
        case 0x5F: return 0xBD                                 // _
        case 0x2B: return 0xBB                                 // +
        case 0x7B: return 0xDB                                 // {
        case 0x7D: return 0xDD                                 // }
        case 0x7C: return 0xDC                                 // |
        case 0x3A: return 0xBA                                 // :
        case 0x22: return 0xDE                                 // "
        case 0x3C: return 0xBC                                 // <
        case 0x3E: return 0xBE                                 // >
        case 0x3F: return 0xBF                                 // ?
        case 0x7E: return 0xC0                                 // ~
        default: return nil
        }
    }
}

// MARK: - The session overlay

/// The in-session overlay: the game's name, one honest status line, a close
/// menu and a key row that posts real virtual keys (a platformer is playable
/// on the phone with arrows + space while touch acts as the mouse). Raw UIKit
/// in the same window above the Metal host — SwiftUI content would sit *under*
/// the host, where the guest's frames cover it. Empty areas pass touches
/// through, so the game keeps the full screen.
final class SessionHUDView: UIView {
    var title: String? { didSet { titleLabel.text = title } }
    var line: (() -> String)?
    /// The live launch checklist: non-nil only while a launch is in flight
    /// (the engine's `.starting` phase). The panel hides itself the moment
    /// the game is running.
    var launchState: (() -> LaunchHUDState?)?

    private let titleLabel = UILabel()
    private let statusLabel = HUDInsetLabel()
    private let launchPanel = UIStackView()
    private let launchHeader = UILabel()
    private let launchElapsed = UILabel()
    private let launchCancel = UIButton(type: .system)
    private let launchRows = UIStackView()
    private var stepRows: [(id: String, glyph: UILabel, detail: UILabel)] = []
    private var keyButtons: [HUDKeyButton] = []
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Only real controls take touches; everything else falls through to the
    /// session surface below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
            releaseHeldKeys()
        }
    }

    private func setUp() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.85)

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.92)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        let menuButton = UIButton(type: .system)
        var config = UIButton.Configuration.gray()
        config.title = "Menu"
        config.image = UIImage(systemName: "chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseForegroundColor = .white
        config.cornerStyle = .fixed
        config.background.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        menuButton.configuration = config
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = makeMenu()
        menuButton.accessibilityLabel = "Session menu"
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)

        // Bottom key row: movement on the left, actions on the right.
        let arrows = UIStackView(arrangedSubviews: [
            keyButton("←", 0x25), keyButton("↑", 0x26), keyButton("↓", 0x28), keyButton("→", 0x27),
        ])
        arrows.spacing = 8
        let actions = UIStackView(arrangedSubviews: [
            keyButton("ESC", 0x1B), keyButton("TAB", 0x09), keyButton("ENTER", 0x0D), keyButton("SPACE", 0x20),
        ])
        actions.spacing = 8
        let keyRow = UIStackView(arrangedSubviews: [arrows, actions])
        keyRow.spacing = 22
        keyRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyRow)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),

            menuButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            menuButton.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),

            keyRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            keyRow.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            keyRow.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            keyRow.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        setUpLaunchPanel(textStack: textStack)
    }

    /// The start checklist. Built once; its rows are rebuilt only when a new
    /// launch's step list replaces the old one (see `refreshLaunchPanel`).
    private func setUpLaunchPanel(textStack: UIStackView) {
        launchPanel.axis = .vertical
        launchPanel.spacing = 6
        launchPanel.isLayoutMarginsRelativeArrangement = true
        launchPanel.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        launchPanel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        launchPanel.layer.cornerRadius = 14
        launchPanel.layer.borderWidth = 1
        launchPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        launchPanel.translatesAutoresizingMaskIntoConstraints = false
        launchPanel.isHidden = true
        addSubview(launchPanel)

        launchHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        launchHeader.textColor = UIColor.white.withAlphaComponent(0.9)
        launchHeader.text = "Starting the game"
        launchElapsed.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        launchElapsed.textColor = UIColor.white.withAlphaComponent(0.65)
        launchCancel.setTitle("Cancel", for: .normal)
        launchCancel.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        launchCancel.addTarget(self, action: #selector(cancelLaunch), for: .touchUpInside)

        let headerRow = UIStackView(arrangedSubviews: [launchHeader, launchElapsed, UIView(), launchCancel])
        headerRow.axis = .horizontal
        headerRow.spacing = 8
        launchRows.axis = .vertical
        launchRows.spacing = 4
        launchPanel.addArrangedSubview(headerRow)
        launchPanel.addArrangedSubview(launchRows)

        NSLayoutConstraint.activate([
            launchPanel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            launchPanel.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 10),
            launchPanel.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    @objc private func cancelLaunch() {
        WindozEngine.shared.cancelLaunch()
    }

    private func keyButton(_ label: String, _ vk: Int32) -> HUDKeyButton {
        let button = HUDKeyButton(label: label, vk: vk)
        keyButtons.append(button)
        return button
    }

    private func makeMenu() -> UIMenu {
        UIMenu(title: "Session", children: [
            UIAction(title: "Close the game (Alt+F4)", image: UIImage(systemName: "escape")) { _ in
                WindozEngine.shared.requestQuit()
            },
            UIAction(title: "Leave the session screen",
                     image: UIImage(systemName: "rectangle.portrait.and.arrow.right")) { _ in
                WindozEngine.shared.detachSession(reason: "You left the session screen.")
            },
        ])
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.15
        refresh()
    }

    private func refresh() {
        let text = line?() ?? ""
        if statusLabel.text != text { statusLabel.text = text }
        refreshLaunchPanel()
    }

    /// Live checklist while a launch is in flight; hidden otherwise. Runs on
    /// the HUD's own 0.5 s timer — cheap, and only while the panel is up is
    /// anything rebuilt.
    private func refreshLaunchPanel() {
        guard let state = launchState?() else {
            if !launchPanel.isHidden { launchPanel.isHidden = true }
            return
        }
        rebuildStepRowsIfNeeded(state.steps)
        launchElapsed.text = "\(Int(state.elapsed)) s"
        for (index, step) in state.steps.enumerated() where index < stepRows.count {
            let row = stepRows[index]
            row.glyph.text = Self.glyph(for: step.state)
            row.glyph.textColor = Self.color(for: step.state)
            if row.detail.text != step.detail { row.detail.text = step.detail }
        }
        launchPanel.isHidden = false
    }

    private func rebuildStepRowsIfNeeded(_ steps: [LaunchStep]) {
        if stepRows.map({ $0.id }) == steps.map({ $0.id }) { return }
        launchRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stepRows = steps.map { step in
            let glyph = UILabel()
            glyph.font = .systemFont(ofSize: 12, weight: .semibold)
            glyph.textAlignment = .center
            glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
            glyph.text = Self.glyph(for: step.state)
            glyph.textColor = Self.color(for: step.state)

            let title = UILabel()
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = UIColor.white.withAlphaComponent(0.9)
            title.text = step.title
            let detail = UILabel()
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = UIColor.white.withAlphaComponent(0.55)
            detail.numberOfLines = 2

            let text = UIStackView(arrangedSubviews: [title, detail])
            text.axis = .vertical
            text.spacing = 1
            let row = UIStackView(arrangedSubviews: [glyph, text])
            row.axis = .horizontal
            row.spacing = 6
            row.alignment = .top
            launchRows.addArrangedSubview(row)
            return (step.id, glyph, detail)
        }
    }

    private static func glyph(for state: LaunchStep.State) -> String {
        switch state {
        case .pending: return "○"
        case .running: return "●"
        case .done: return "✓"
        case .failed: return "✕"
        case .skipped: return "–"
        }
    }

    private static func color(for state: LaunchStep.State) -> UIColor {
        switch state {
        case .pending: return UIColor.white.withAlphaComponent(0.3)
        case .running: return UIColor(red: 0.42, green: 0.65, blue: 1.0, alpha: 1)
        case .done: return UIColor(red: 0.35, green: 0.85, blue: 0.5, alpha: 1)
        case .failed: return UIColor(red: 1.0, green: 0.42, blue: 0.38, alpha: 1)
        case .skipped: return UIColor.white.withAlphaComponent(0.4)
        }
    }

    private func releaseHeldKeys() {
        keyButtons.forEach { $0.releaseIfDown() }
    }
}

/// What the start screen's checklist needs from the engine, read through a
/// closure on each HUD tick (never stored: the engine is the source of truth).
struct LaunchHUDState {
    var steps: [LaunchStep]
    var elapsed: TimeInterval
}

/// A status chip: label + inner padding, dark translucent capsule.
final class HUDInsetLabel: UILabel {
    private let insets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 9
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}

/// A keycap that posts a real virtual key down/up pair while held.
final class HUDKeyButton: UIButton {
    private let vk: Int32
    private var keyDown = false
    private static let idleColor = UIColor.black.withAlphaComponent(0.45)
    private static let heldColor = UIColor.white.withAlphaComponent(0.35)

    init(label: String, vk: Int32) {
        self.vk = vk
        super.init(frame: .zero)
        setTitle(label, for: .normal)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        backgroundColor = Self.idleColor
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: label.count > 1 ? 58 : 46),
            heightAnchor.constraint(equalToConstant: 40),
        ])
        accessibilityLabel = "Key \(label)"
        addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(pressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func pressDown() {
        guard !keyDown else { return }
        keyDown = true
        backgroundColor = Self.heldColor
        winios_post_key(vk, 1)
    }

    @objc private func pressUp() {
        guard keyDown else { return }
        keyDown = false
        backgroundColor = Self.idleColor
        winios_post_key(vk, 0)
    }

    func releaseIfDown() { pressUp() }
}

// MARK: - The session screen

/// The full-screen session: the touch/keyboard surface, plus the overlay as a
/// window-level view above the presenting layer. Nothing else is drawn below
/// the guest's frames.
struct GameSessionView: View {
    let game: InstalledGame

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SessionSurfaceRepresentable()
                .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct SessionSurfaceRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> SessionSurfaceView { SessionSurfaceView() }
    func updateUIView(_ uiView: SessionSurfaceView, context: Context) {}
}
