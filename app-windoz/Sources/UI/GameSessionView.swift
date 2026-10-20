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
import Darwin

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
        // The drawable belongs to DXMT: it sizes the layer from the guest's
        // swapchain, off the main thread. The app must not write this after
        // registration — doing so raced DXMT and could leave a stale surface
        // presenting (the freeze-after-boot finding). The seed below only
        // exists so a layer created before the first guest frame is valid.
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
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
    private lazy var controls = SessionPadOverlayView()
    private lazy var keyboard = SessionKeyboardMouseOverlayView()
    private lazy var stats = SessionPerformanceView()

    /// Rotation and guest-display observers. Re-installed per presentation and
    /// removed on teardown; one session at a time.
    private var displayObservers: [NSObjectProtocol] = []
    private var drawableObservation: NSKeyValueObservation?
    private var settleWork: DispatchWorkItem?

    /// The session's pointer contract. `.touchscreen` keeps the original direct
    /// touch mapping; `.trackpad` owns a desktop-pixel cursor and posts mouse
    /// events instead of touches.
    private var pointerMode = SessionPreferences.pointerMode
    private var pointerSensitivity = SessionPreferences.trackpadSensitivity
    private var trackpadTouch: UITouch?
    private var trackpadLastPoint = CGPoint.zero
    private var trackpadStartPoint = CGPoint.zero
    private var trackpadStartTime: CFTimeInterval = 0
    private var trackpadMoved = false
    private var trackpadDragging = false
    private var trackpadGeneration = 0
    private var trackpadTwoFinger = false
    private var trackpadTwoFingerMoved = false
    private var trackpadTwoFingerStartTime: CFTimeInterval = 0
    private var trackpadLastTwoFingerY: CGFloat = 0
    private var trackpadScrollAccum: CGFloat = 0
    private var lastTapTime: CFTimeInterval = 0
    private var lastTapPoint = CGPoint.zero
    private var cursor = CGPoint.zero
    private var cursorReady = false

    private let F_MOVE: UInt32 = 0x1, F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10
    private let F_WHEEL: UInt32 = 0x800, F_ABS: UInt32 = 0x8000

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

    private var gameRect: CGRect {
        guard let window else { return .zero }
        return convert(gameRectInWindow, from: window)
    }

    /// The aspect-fit guest rectangle in window coordinates. Using the window,
    /// not this view's own bounds, keeps the host and compositor geometry
    /// correct even while SwiftUI is still settling a rotation.
    private var gameRectInWindow: CGRect {
        guard let window else { return .zero }
        return SessionSurfaceLayout.fittingRect(guest: guestSize, in: window.bounds)
    }

    private func containsInGame(_ point: CGPoint) -> Bool {
        guard let window else { return false }
        return gameRectInWindow.contains(convert(point, to: window))
    }

    /// True when the engine is hosting a Windows desktop (Doz Dock or the full
    /// Steam client). The compositor owns the mapping there, and a trackpad
    /// cursor is drawn by it.
    private var isDesktopSession: Bool {
        guard let value = getenv("MADEIRA_DESKTOP") else { return false }
        return value.pointee == 49   // '1'
    }

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
        // Show the desktop compositor only for a desktop session. A direct
        // game's game-mode compositor is created later; hiding it here (or on
        // a SwiftUI reattach) would be read as "session ended" and drop its
        // windows. Teardown, not attach, owns hiding.
        if isDesktopSession { winios_compositor_set_hidden(0) }
        attachControls(to: window)
        attachHUD(to: window)
        applyLayout()
        installDisplayObservers()
        observeDrawableSize()

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
        if let window {
            layoutOverlays(in: window)
            window.bringSubviewToFront(controls)
            window.bringSubviewToFront(keyboard)
            window.bringSubviewToFront(stats)
            window.bringSubviewToFront(hud)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        refreshDisplay(reason: "safe area")
    }

    /// The one place presentation geometry is published. The Metal host is
    /// sized to the aspect-fit guest rect; the engine's desktop compositor is
    /// told the whole session frame and the same guest rect, so it can letterbox
    /// and map clicks exactly the way the host presents. DXMT owns the layer's
    /// `drawableSize` — writing it here raced its off-main update and could
    /// leave a stale frame presenting.
    private func applyLayout() {
        guard let window else { return }
        let host = WindozMetalHostView.shared
        let rect = gameRectInWindow
        if host.frame != rect { host.frame = rect }

        let frame = window.bounds
        winios_set_compositor_frame(Double(frame.minX), Double(frame.minY),
                                    Double(frame.width), Double(frame.height))
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        winios_set_desktop_rect(Double(local.minX), Double(local.minY),
                                Double(local.width), Double(local.height), 1)
    }

    private func layoutOverlays(in window: UIWindow) {
        let frame = window.bounds
        if controls.superview === window, controls.frame != frame {
            controls.frame = frame
        }
        if keyboard.superview === window, keyboard.frame != frame {
            keyboard.frame = frame
        }
        if hud.superview === window, hud.frame != frame {
            hud.frame = frame
        }
        if stats.superview === window {
            let safe = window.safeAreaInsets
            stats.frame = CGRect(x: frame.width - safe.right - 12 - 208,
                                 y: safe.top + 54, width: 208, height: 96)
        }
    }

    /// Re-publish after a rotation, a guest display-mode change, or a stall.
    /// iOS reports the new orientation before the settled window bounds and
    /// safe area exist, so run once now and once after a short settle.
    private func refreshDisplay(reason: String) {
        guard window != nil else { return }
        applyLayout()
        if let window { layoutOverlays(in: window) }
        hud.setNeedsLayout()
        hud.layoutIfNeeded()
        controls.setNeedsLayout()
        controls.layoutIfNeeded()
        keyboard.setNeedsLayout()
        keyboard.layoutIfNeeded()
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyLayout()
            if let window = self.window { self.layoutOverlays(in: window) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        if reason != "safe area" {
            EngineLogStream.shared.append("[session] display refresh: \(reason).")
        }
    }

    private func installDisplayObservers() {
        removeDisplayObservers()
        let center = NotificationCenter.default
        displayObservers.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplay(reason: "rotation")
        })
        displayObservers.append(center.addObserver(forName: Notification.Name.MadeiraDisplayModeChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplay(reason: "guest display mode")
        })
        displayObservers.append(center.addObserver(forName: .windozSessionDisplayRefresh,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplay(reason: "frame stall")
        })
        displayObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window != nil else { return }
            // Only a desktop session owns the compositor. For a direct game,
            // `winios_compositor_set_hidden(1)` means "session ended" to a
            // game-mode compositor and would drop its windows; do not touch it.
            if self.isDesktopSession { winios_compositor_set_hidden(0) }
            self.refreshDisplay(reason: "foreground")
        })
        displayObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.releaseTrackpad()
        })
    }

    private func removeDisplayObservers() {
        let center = NotificationCenter.default
        for observer in displayObservers { center.removeObserver(observer) }
        displayObservers.removeAll()
    }

    /// DXMT resizes the drawable when the guest's swapchain or display mode
    /// changes. The app must not write it, but it should re-run its own layout
    /// when it changes so the host and compositor rects stay in step.
    private func observeDrawableSize() {
        drawableObservation?.invalidate()
        drawableObservation = WindozMetalHostView.shared.metalLayer.observe(\.drawableSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.window != nil else { return }
                self.applyLayout()
            }
        }
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
        hud.controlLayout = { [weak self] in self?.sessionLayout ?? .keyboardMouse }
        hud.onControlLayoutChange = { [weak self] layout in self?.applyControlLayout(layout) }
        hud.performanceEnabled = { SessionPerformanceView.isEnabled }
        hud.onTogglePerformance = { [weak self] in self?.togglePerformance() }
        hud.pointerMode = { [weak self] in self?.pointerMode ?? SessionPreferences.pointerMode }
        hud.onPointerModeChange = { [weak self] mode in self?.applyPointerMode(mode) }
        hud.pointerSensitivity = { [weak self] in
            self?.pointerSensitivity ?? SessionPreferences.trackpadSensitivity
        }
        hud.onPointerSensitivityChange = { [weak self] value in
            self?.applyPointerSensitivity(value)
        }
        hud.ecoEnabled = { WindozEngine.shared.ecoEnabled }
        hud.ecoAvailable = { WindozEngine.shared.ecoIsAvailable }
        hud.onToggleEco = { WindozEngine.shared.setEco(!WindozEngine.shared.ecoEnabled) }
        hud.directInput = { [weak self] in self?.sessionGameSettings()?.dinputPad ?? false }
        hud.onToggleDirectInput = { [weak self] in
            self?.updateGameSettings { $0.dinputPad.toggle() }
        }
        hud.gameResolution = { [weak self] in self?.sessionGameSettings()?.resolution ?? .scaled }
        hud.onResolutionChange = { [weak self] resolution in
            self?.updateGameSettings { $0.resolution = resolution }
        }
        hud.dockStage = {
            let engine = WindozEngine.shared
            if let failure = engine.dockFailure { return (failure, true) }
            if let stage = engine.dockStage { return (stage, false) }
            return nil
        }
    }

    /// The session's control layout: the game's stored choice, read live so a
    /// change made in the settings menu is what the next session starts with.
    private var sessionLayout: ControlLayout {
        guard let id = WindozEngine.shared.sessionGame?.id,
              let game = GameLibrary.shared.game(withID: id) else { return .keyboardMouse }
        return game.settings.controlLayout
    }

    private func sessionGameSettings() -> GameSettings? {
        guard let id = WindozEngine.shared.sessionGame?.id,
              let game = GameLibrary.shared.game(withID: id) else { return nil }
        return game.settings
    }

    private func updateGameSettings(_ change: (inout GameSettings) -> Void) {
        guard let id = WindozEngine.shared.sessionGame?.id,
              var game = GameLibrary.shared.game(withID: id) else { return }
        change(&game.settings)
        GameLibrary.shared.setSettings(game.settings, for: id)
    }

    private func attachControls(to window: UIWindow) {
        if controls.superview !== window {
            controls.removeFromSuperview()
            window.addSubview(controls)
        }
        controls.frame = window.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.layout = sessionLayout

        if keyboard.superview !== window {
            keyboard.removeFromSuperview()
            window.addSubview(keyboard)
        }
        keyboard.frame = window.bounds
        keyboard.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyboard.layout = sessionLayout
        keyboard.isHidden = sessionLayout != .keyboardMouse

        SessionGamepad.shared.activate(layout: sessionLayout)

        if stats.superview !== window {
            stats.removeFromSuperview()
            window.addSubview(stats)
        }
        stats.isShown = SessionPerformanceView.isEnabled
    }

    private func applyControlLayout(_ layout: ControlLayout) {
        controls.layout = layout
        keyboard.layout = layout
        SessionGamepad.shared.setLayout(layout)
        updateGameSettings { $0.controlLayout = layout }
    }

    private func applyPointerMode(_ mode: PointerMode) {
        guard mode != pointerMode else { return }
        endPrimaryTouch()
        releaseTrackpad()
        pointerMode = mode
        SessionPreferences.pointerMode = mode
        EngineLogStream.shared.append("[session] pointer mode: \(mode.title).")
    }

    private func applyPointerSensitivity(_ value: Double) {
        SessionPreferences.trackpadSensitivity = value
        pointerSensitivity = SessionPreferences.trackpadSensitivity
        EngineLogStream.shared.append(
            "[session] pointer sensitivity: \(String(format: "%.2f", pointerSensitivity))× (trackpad and right stick).")
    }

    private func togglePerformance() {
        let enabled = !SessionPerformanceView.isEnabled
        SessionPerformanceView.isEnabled = enabled
        stats.isShown = enabled
    }

    private func teardown() {
        removeDisplayObservers()
        drawableObservation?.invalidate(); drawableObservation = nil
        settleWork?.cancel(); settleWork = nil
        endPrimaryTouch()
        releaseTrackpad()
        WindozMetalHostView.shared.isHidden = true
        winios_compositor_set_hidden(1)
        SessionGamepad.shared.deactivate()
        keyboard.releaseAllKeys()
        keyboard.removeFromSuperview()
        controls.removeFromSuperview()
        stats.stop()
        stats.removeFromSuperview()
        hud.removeFromSuperview()
    }

    // MARK: Touch → guest

    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        // `event.allTouches` also carries fingers held on the joystick, Space,
        // Esc or Tab. Only touches delivered to this surface may count as a
        // trackpad gesture; otherwise holding a control while looking around
        // would be misread as a two-finger scroll.
        (event?.allTouches ?? []).filter {
            $0.view === self && $0.phase != .ended && $0.phase != .cancelled
        }
    }

    /// Maps a view point to guest pixels. In a desktop session the engine's
    /// compositor owns the letterbox mapping (including desktop-fit windows),
    /// so ask it first; direct sessions use the same aspect-fit rectangle the
    /// Metal host presents in.
    private func guestPoint(for point: CGPoint) -> (Int32, Int32) {
        if let window {
            let windowPoint = convert(point, to: window)
            if isDesktopSession {
                var x: Int32 = 0, y: Int32 = 0
                if winios_desktop_point_from_window(Double(windowPoint.x), Double(windowPoint.y), &x, &y) != 0 {
                    return (x, y)
                }
            }
            let rect = SessionSurfaceLayout.fittingRect(guest: guestSize, in: window.bounds)
            return SessionSurfaceLayout.guestPoint(windowPoint, rect: rect, guest: guestSize)
        }
        return SessionSurfaceLayout.guestPoint(point, rect: gameRect, guest: guestSize)
    }

    private func endPrimaryTouch() {
        guard let touch = primaryTouch else { return }
        let (x, y) = guestPoint(for: touch.location(in: self))
        winios_post_touch_up(x, y)
        primaryTouch = nil
    }

    // MARK: Trackpad pointer

    private func averagePoint(_ touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for touch in touches {
            let point = touch.location(in: self)
            x += point.x; y += point.y
        }
        let count = CGFloat(max(touches.count, 1))
        return CGPoint(x: x / count, y: y / count)
    }

    private func prepareCursor() {
        guard !cursorReady else { return }
        let guest = guestSize
        cursor = CGPoint(x: guest.width / 2, y: guest.height / 2)
        cursorReady = true
        // `winios_cursor_move` only moves the drawn arrow (a no-op on iOS);
        // Wine learns the position from an absolute pointer event.
        winios_cursor_move(Int32(cursor.x), Int32(cursor.y))
        postPointer(F_MOVE | F_ABS)
    }

    private func postPointer(_ flags: UInt32, data: Int32 = 0) {
        winios_pointer(Int32(cursor.x), Int32(cursor.y), flags, UInt32(bitPattern: data))
    }

    private func moveCursor(dx: CGFloat, dy: CGFloat) {
        var width: Int32 = 0, height: Int32 = 0
        winios_screen_size(&width, &height)
        let size = (width > 0 && height > 0)
            ? CGSize(width: CGFloat(width), height: CGFloat(height))
            : guestSize
        let maxX = CGFloat(max(Int(size.width), 1) - 1)
        let maxY = CGFloat(max(Int(size.height), 1) - 1)
        cursor.x = min(max(cursor.x + dx, 0), maxX)
        cursor.y = min(max(cursor.y + dy, 0), maxY)
        postPointer(F_MOVE | F_ABS)
    }

    /// Releases every button and forgets gesture state. Called on mode change,
    /// teardown, backgrounding and cancellation — never leave a button down.
    private func releaseTrackpad() {
        trackpadGeneration += 1
        if trackpadDragging { postPointer(F_LUP) }
        trackpadDragging = false
        trackpadTwoFinger = false
        trackpadTwoFingerMoved = false
        trackpadScrollAccum = 0
        trackpadTouch = nil
        lastTapTime = 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerMode == .touchscreen else {
            beginTrackpad(touches, event: event)
            return
        }
        guard primaryTouch == nil, let touch = touches.first,
              gameRect.contains(touch.location(in: self)) else { return }
        primaryTouch = touch
        let (x, y) = guestPoint(for: touch.location(in: self))
        winios_post_touch_down(x, y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerMode == .touchscreen else {
            moveTrackpad(touches, event: event)
            return
        }
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        let (x, y) = guestPoint(for: touch.location(in: self))
        winios_post_touch_move(x, y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerMode == .touchscreen else {
            endTrackpad(touches, event: event, cancelled: false)
            return
        }
        guard let touch = primaryTouch, touches.contains(touch) else { return }
        let (x, y) = guestPoint(for: touch.location(in: self))
        winios_post_touch_up(x, y)
        primaryTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerMode == .touchscreen else {
            endTrackpad(touches, event: event, cancelled: true)
            return
        }
        touchesEnded(touches, with: event)
    }

    private func beginTrackpad(_ touches: Set<UITouch>, event: UIEvent?) {
        prepareCursor()
        let now = CACurrentMediaTime()
        let active = activeTouches(event)

        if active.count >= 2 {
            trackpadTwoFinger = true
            trackpadTwoFingerMoved = false
            trackpadTwoFingerStartTime = now
            trackpadLastTwoFingerY = averagePoint(active).y
            trackpadScrollAccum = 0
            trackpadGeneration += 1
            // The first finger must not resume as a one-finger pan with a
            // stale anchor when the second one leaves.
            trackpadTouch = nil
            trackpadMoved = false
            if trackpadDragging {
                postPointer(F_LUP)
                trackpadDragging = false
            }
            return
        }

        guard trackpadTouch == nil, let touch = touches.first else { return }
        let point = touch.location(in: self)
        trackpadTouch = touch
        trackpadStartPoint = point
        trackpadLastPoint = point
        trackpadStartTime = now
        trackpadMoved = false
        trackpadDragging = false
        trackpadTwoFinger = false
        trackpadGeneration += 1
        let generation = trackpadGeneration

        // Hold still for 0.45 s to arm a drag; a quick tap is a click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.trackpadGeneration == generation,
                  !self.trackpadMoved, !self.trackpadTwoFinger,
                  !self.trackpadDragging, self.trackpadTouch != nil else { return }
            self.trackpadDragging = true
            self.postPointer(self.F_LDOWN)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func moveTrackpad(_ touches: Set<UITouch>, event: UIEvent?) {
        let active = activeTouches(event)
        if trackpadTwoFinger {
            guard active.count >= 2 else { return }
            let y = averagePoint(active).y
            let dy = y - trackpadLastTwoFingerY
            trackpadLastTwoFingerY = y
            if abs(dy) > 2 { trackpadTwoFingerMoved = true }
            trackpadScrollAccum += dy
            // 14 pt of finger travel is one Windows wheel notch. Dragging up
            // scrolls down through the document, like a touch surface.
            while trackpadScrollAccum <= -14 {
                trackpadScrollAccum += 14
                postPointer(F_WHEEL, data: -120)
            }
            while trackpadScrollAccum >= 14 {
                trackpadScrollAccum -= 14
                postPointer(F_WHEEL, data: 120)
            }
            return
        }

        guard let touch = trackpadTouch, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        let dx = point.x - trackpadLastPoint.x
        let dy = point.y - trackpadLastPoint.y
        trackpadLastPoint = point
        if hypot(point.x - trackpadStartPoint.x, point.y - trackpadStartPoint.y) > 10 {
            trackpadMoved = true
        }

        // One finger moves the pointer relative to where it is, like a laptop
        // pad. Scale the view delta to guest pixels so the pointer tracks what
        // is drawn under the finger, then apply the persisted sensitivity.
        // The cursor is a CGFloat, so sub-pixel movement accumulates instead
        // of being dropped at slow speeds.
        let rect = gameRect
        guard rect.width > 0, rect.height > 0 else { return }
        let scale = CGFloat(max(guestSize.width / rect.width, 0.5) * pointerSensitivity)
        moveCursor(dx: dx * scale, dy: dy * scale)
    }

    private func endTrackpad(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        let now = CACurrentMediaTime()
        if trackpadTwoFinger {
            if activeTouches(event).isEmpty {
                if !cancelled, !trackpadTwoFingerMoved, now - trackpadTwoFingerStartTime < 0.40 {
                    postPointer(F_RDOWN)
                    postPointer(F_RUP)
                }
                trackpadTwoFinger = false
                trackpadTwoFingerMoved = false
                trackpadScrollAccum = 0
            }
            return
        }

        guard let touch = trackpadTouch, touches.contains(touch) else { return }
        trackpadGeneration += 1
        if trackpadDragging {
            postPointer(F_LUP)
            trackpadDragging = false
            trackpadTouch = nil
            return
        }
        if !cancelled, !trackpadMoved, now - trackpadStartTime < 0.5 {
            postPointer(F_LDOWN)
            postPointer(F_LUP)
            // A second tap close to the first is a double-click. The first tap
            // has already produced one click; this one completes the pair,
            // which is how Windows recognises a double-click.
            let point = touch.location(in: self)
            let doubled = now - lastTapTime < 0.35
                && hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y) < 30
            if doubled {
                postPointer(F_LDOWN)
                postPointer(F_LUP)
                lastTapTime = 0
            } else {
                lastTapTime = now
                lastTapPoint = point
            }
        }
        trackpadTouch = nil
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

    /// Session settings, read through closures on each tick so the engine and
    /// the library stay the source of truth.
    var controlLayout: (() -> ControlLayout)?
    var onControlLayoutChange: ((ControlLayout) -> Void)?
    var performanceEnabled: (() -> Bool)?
    var onTogglePerformance: (() -> Void)?
    var pointerMode: (() -> PointerMode)?
    var onPointerModeChange: ((PointerMode) -> Void)?
    var pointerSensitivity: (() -> Double)?
    var onPointerSensitivityChange: ((Double) -> Void)?
    var ecoEnabled: (() -> Bool)?
    var ecoAvailable: (() -> Bool)?
    var onToggleEco: (() -> Void)?
    var directInput: (() -> Bool)?
    var onToggleDirectInput: (() -> Void)?
    var gameResolution: (() -> GameResolution)?
    var onResolutionChange: ((GameResolution) -> Void)?
    /// Doz Dock's live progress (or the honest refusal while the session still
    /// runs). Nil when the session is not a dock session.
    var dockStage: (() -> (text: String, failed: Bool)?)?

    private let titleLabel = UILabel()
    private let statusLabel = HUDInsetLabel()
    private let dockLabel = HUDInsetLabel()
    private let gearButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let launchPanel = UIStackView()
    private let launchHeader = UILabel()
    private let launchElapsed = UILabel()
    private let launchCancel = UIButton(type: .system)
    private let launchRows = UIStackView()
    private var stepRows: [(id: String, glyph: UILabel, detail: UILabel)] = []
    private var timer: Timer?

    /// The session menu and settings are an in-HUD panel built from controls
    /// that live in this window, not UIMenu. 0.9.0 hung both buttons off
    /// `showsMenuAsPrimaryAction`; the HUD is added directly to the UIWindow
    /// and has no owning view controller, so UIKit had no presenter and both
    /// buttons were dead on device. Target/action buttons have no such
    /// requirement.
    private enum PanelKind { case menu, settings }
    private var panelKind: PanelKind?
    private let panelBackdrop = UIControl()
    private let panelContainer = UIView()
    private let panelTitle = UILabel()
    private let panelClose = UIButton(type: .system)
    private let panelScroll = UIScrollView()
    private let panelStack = UIStackView()
    private var sensitivityLabel = UILabel()

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
        }
    }

    private func setUp() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        titleLabel.textAlignment = .center

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        statusLabel.textAlignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.7
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.alignment = .center
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        // Two compact icon buttons, plain target/action. The old "Menu ˅" text
        // button grew with the content inset and could not be relied on after
        // a rotation; a fixed 38-point target with no title does not depend on
        // the title's intrinsic size.
        configureIconButton(menuButton, image: "line.3.horizontal",
                            label: "Session menu", action: #selector(openMenuPanel))
        configureIconButton(gearButton, image: "gearshape.fill",
                            label: "Session settings", action: #selector(openSettingsPanel))

        let textCenter = textStack.centerXAnchor.constraint(equalTo: centerXAnchor)
        textCenter.priority = .defaultHigh
        NSLayoutConstraint.activate([
            textCenter,
            textStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            textStack.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 64),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: gearButton.leadingAnchor, constant: -8),
            textStack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            menuButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            menuButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.widthAnchor.constraint(equalToConstant: 38),
            menuButton.heightAnchor.constraint(equalToConstant: 38),

            gearButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -8),
            gearButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            gearButton.widthAnchor.constraint(equalToConstant: 38),
            gearButton.heightAnchor.constraint(equalToConstant: 38),
        ])
        setUpDockLabel(textStack: textStack)
        setUpLaunchPanel(textStack: textStack)
        setUpPanel()
    }

    private func configureIconButton(_ button: UIButton, image: String, label: String, action: Selector) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 19
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
    }

    /// The panel is a normal view hierarchy inside the HUD. It is deliberately
    /// not a UIMenu and not a presented view controller: the HUD lives in the
    /// UIWindow with no owning controller, and both of those presentations
    /// need one.
    private func setUpPanel() {
        panelBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        panelBackdrop.translatesAutoresizingMaskIntoConstraints = false
        panelBackdrop.isHidden = true
        panelBackdrop.addTarget(self, action: #selector(dismissPanel), for: .touchUpInside)
        addSubview(panelBackdrop)

        panelContainer.backgroundColor = UIColor(white: 0.08, alpha: 0.97)
        panelContainer.layer.cornerRadius = 18
        panelContainer.layer.borderWidth = 1
        panelContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        panelContainer.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.isHidden = true
        addSubview(panelContainer)

        panelTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        panelTitle.textColor = .white
        panelTitle.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(panelTitle)

        panelClose.setTitle("Done", for: .normal)
        panelClose.setTitleColor(Theme.accent, for: .normal)
        panelClose.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        panelClose.addTarget(self, action: #selector(dismissPanel), for: .touchUpInside)
        panelClose.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(panelClose)

        panelScroll.alwaysBounceVertical = true
        panelScroll.showsVerticalScrollIndicator = true
        panelScroll.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(panelScroll)

        panelStack.axis = .vertical
        panelStack.spacing = 6
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        panelScroll.addSubview(panelStack)

        let width = panelContainer.widthAnchor.constraint(equalToConstant: 360)
        width.priority = .defaultHigh
        let height = panelContainer.heightAnchor.constraint(equalToConstant: 500)
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            panelBackdrop.topAnchor.constraint(equalTo: topAnchor),
            panelBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            panelBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            panelBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            panelContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
            panelContainer.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor,
                                                     constant: 12),
            panelContainer.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor,
                                                      constant: -12),
            height,
            panelContainer.heightAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.heightAnchor,
                                                    constant: -24),
            panelContainer.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor,
                                                constant: 8),
            panelContainer.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor,
                                                   constant: -8),

            panelTitle.topAnchor.constraint(equalTo: panelContainer.topAnchor, constant: 16),
            panelTitle.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor, constant: 16),
            panelTitle.trailingAnchor.constraint(lessThanOrEqualTo: panelClose.leadingAnchor, constant: -8),
            panelClose.centerYAnchor.constraint(equalTo: panelTitle.centerYAnchor),
            panelClose.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor, constant: -16),

            panelScroll.topAnchor.constraint(equalTo: panelTitle.bottomAnchor, constant: 10),
            panelScroll.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor, constant: 12),
            panelScroll.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor, constant: -12),
            panelScroll.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor, constant: -12),

            panelStack.topAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.topAnchor, constant: 4),
            panelStack.bottomAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.bottomAnchor, constant: -4),
            panelStack.leadingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.leadingAnchor),
            panelStack.trailingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.trailingAnchor),
            panelStack.widthAnchor.constraint(equalTo: panelScroll.frameLayoutGuide.widthAnchor),
        ])
    }

    @objc private func openMenuPanel() {
        EngineLogStream.shared.append("[session] menu button tapped.")
        presentPanel(.menu)
    }

    @objc private func openSettingsPanel() {
        EngineLogStream.shared.append("[session] settings button tapped.")
        presentPanel(.settings)
    }

    private func presentPanel(_ kind: PanelKind) {
        panelKind = kind
        rebuildPanel()
        panelBackdrop.isHidden = false
        panelContainer.isHidden = false
        bringSubviewToFront(panelBackdrop)
        bringSubviewToFront(panelContainer)
        EngineLogStream.shared.append("[session] \(kind == .menu ? "session menu" : "session settings") panel opened.")
    }

    @objc private func dismissPanel() {
        guard panelKind != nil else { return }
        EngineLogStream.shared.append("[session] \(panelKind == .menu ? "session menu" : "session settings") panel closed.")
        panelKind = nil
        panelBackdrop.isHidden = true
        panelContainer.isHidden = true
        clearPanelRows()
    }

    private func clearPanelRows() {
        for view in panelStack.arrangedSubviews {
            panelStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func rebuildPanel(preservingOffset: Bool = false) {
        guard let kind = panelKind else { return }
        let offset = preservingOffset ? panelScroll.contentOffset : .zero
        clearPanelRows()
        panelTitle.text = kind == .settings ? "Session settings" : "Session"

        switch kind {
        case .menu:
            addPanelHeader("THIS SESSION")
            addPanelRow("Close the game (Alt+F4)",
                        detail: "Asks Windows to close the running game.") { [weak self] in
                self?.dismissPanel()
                WindozEngine.shared.requestQuit()
            }
            addPanelRow("Leave the session screen",
                        detail: "Keeps Windows running in the background.") { [weak self] in
                self?.dismissPanel()
                WindozEngine.shared.detachSession(reason: "You left the session screen.")
            }
            addPanelHeader("APP")
            addPanelRow("Quit Windoz (restart the app)",
                        detail: "Ends this app run; downloads and the library stay.",
                        destructive: true) { [weak self] in
                self?.dismissPanel()
                AppContainer.quitNow(reason: "quitting from the session menu")
            }

        case .settings:
            let layout = controlLayout?() ?? .keyboardMouse
            addPanelHeader("CONTROLS")
            for choice in ControlLayout.allCases {
                addPanelRow(choice.title, selected: choice == layout) { [weak self] in
                    EngineLogStream.shared.append("[session] settings: controls → \(choice.title).")
                    self?.onControlLayoutChange?(choice)
                    self?.rebuildPanel(preservingOffset: true)
                }
            }

            let pointer = pointerMode?() ?? .touchscreen
            addPanelHeader("POINTER")
            for choice in PointerMode.allCases {
                addPanelRow(choice.title,
                            detail: choice == .trackpad
                                ? "Relative pointer, tap to click, two-finger scroll."
                                : "The finger is the pointer, directly on the game.",
                            selected: choice == pointer) { [weak self] in
                    EngineLogStream.shared.append("[session] settings: pointer → \(choice.title).")
                    self?.onPointerModeChange?(choice)
                    self?.rebuildPanel(preservingOffset: true)
                }
            }
            addSensitivityRow()

            addPanelHeader("DISPLAY")
            addPanelRow("Performance stats",
                        detail: "Frame pacing, FPS and memory in the corner.",
                        selected: performanceEnabled?() ?? false) { [weak self] in
                self?.onTogglePerformance?()
                self?.rebuildPanel(preservingOffset: true)
            }
            let resolution = gameResolution?() ?? .scaled
            for choice in GameResolution.allCases {
                addPanelRow(choice.shortTitle,
                            detail: "Resolution for the next launch.",
                            selected: choice == resolution) { [weak self] in
                    EngineLogStream.shared.append("[session] settings: resolution → \(choice.shortTitle).")
                    self?.onResolutionChange?(choice)
                    self?.rebuildPanel(preservingOffset: true)
                }
            }

            addPanelHeader("PERFORMANCE")
            let eco = ecoEnabled?() ?? false
            let ecoReady = ecoAvailable?() ?? false
            addPanelRow("Eco mode",
                        detail: ecoReady
                            ? (eco ? "On — guest threads use the low-power class."
                                   : "Off — guest threads use the normal class.")
                            : "Not available in this engine build.",
                        selected: eco,
                        enabled: ecoReady) { [weak self] in
                self?.onToggleEco?()
                self?.rebuildPanel(preservingOffset: true)
            }
            addPanelRow("DirectInput joystick",
                        detail: "Applies to the next launch.",
                        selected: directInput?() ?? false) { [weak self] in
                self?.onToggleDirectInput?()
                self?.rebuildPanel(preservingOffset: true)
            }

            addPanelHeader("SESSION")
            addPanelRow("Close the game (Alt+F4)",
                        detail: "Asks Windows to close the running game.",
                        destructive: true) { [weak self] in
                self?.dismissPanel()
                WindozEngine.shared.requestQuit()
            }
            addPanelRow("Close settings") { [weak self] in
                self?.dismissPanel()
            }
        }

        if preservingOffset, offset != .zero {
            panelScroll.layoutIfNeeded()
            panelScroll.setContentOffset(offset, animated: false)
        }
    }

    private func addPanelHeader(_ text: String) {
        if let last = panelStack.arrangedSubviews.last {
            panelStack.setCustomSpacing(14, after: last)
        }
        let label = UILabel()
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        label.text = text
        label.accessibilityTraits = .header
        panelStack.addArrangedSubview(label)
        panelStack.setCustomSpacing(2, after: label)
    }

    private func addPanelRow(_ title: String,
                             detail: String? = nil,
                             selected: Bool = false,
                             destructive: Bool = false,
                             enabled: Bool = true,
                             action: @escaping () -> Void) {
        let row = HUDPanelRow(title: title, detail: detail, selected: selected,
                              destructive: destructive, enabled: enabled)
        row.action = action
        panelStack.addArrangedSubview(row)
    }

    private func addSensitivityRow() {
        let value = pointerSensitivity?() ?? SessionPreferences.trackpadSensitivity
        sensitivityLabel = UILabel()
        sensitivityLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sensitivityLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        sensitivityLabel.text = Self.sensitivityTitle(value)

        let slider = UISlider()
        slider.minimumValue = Float(SessionPreferences.sensitivityRange.lowerBound)
        slider.maximumValue = Float(SessionPreferences.sensitivityRange.upperBound)
        slider.value = Float(value)
        slider.addTarget(self, action: #selector(sensitivityChanged(_:)), for: .valueChanged)
        slider.accessibilityLabel = "Trackpad sensitivity"

        let note = UILabel()
        note.font = .systemFont(ofSize: 11)
        note.textColor = UIColor.white.withAlphaComponent(0.55)
        note.numberOfLines = 0
        note.text = "Applies to one-finger trackpad movement and the controller's right stick."

        if let last = panelStack.arrangedSubviews.last {
            panelStack.setCustomSpacing(8, after: last)
        }
        panelStack.addArrangedSubview(sensitivityLabel)
        panelStack.addArrangedSubview(slider)
        panelStack.addArrangedSubview(note)
    }

    @objc private func sensitivityChanged(_ sender: UISlider) {
        let value = Double(sender.value)
        sensitivityLabel.text = Self.sensitivityTitle(value)
        onPointerSensitivityChange?(value)
    }

    private static func sensitivityTitle(_ value: Double) -> String {
        String(format: "Trackpad sensitivity — %.2f×", value)
    }

    /// Doz Dock's live line: what Valve's client is doing, or the refusal the
    /// host has already reported. Sits under the status chip, above the launch
    /// checklist, and never takes touches.
    private func setUpDockLabel(textStack: UIStackView) {
        dockLabel.font = .systemFont(ofSize: 11, weight: .medium)
        dockLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        dockLabel.numberOfLines = 3
        dockLabel.isHidden = true
        dockLabel.isUserInteractionEnabled = false
        dockLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dockLabel)
        NSLayoutConstraint.activate([
            dockLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            dockLabel.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 8),
            dockLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            dockLabel.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            dockLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
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
            launchPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            launchPanel.topAnchor.constraint(equalTo: dockLabel.bottomAnchor, constant: 8),
            launchPanel.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            launchPanel.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            launchPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    @objc private func cancelLaunch() {
        WindozEngine.shared.cancelLaunch()
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
        refreshDock()
        refreshLaunchPanel()
    }

    /// Doz Dock's live line. The engine reads the host's report every half
    /// second; this only renders it. A refusal is drawn as a red chip so it
    /// cannot be mistaken for a healthy launch.
    private func refreshDock() {
        guard let state = dockStage?() else {
            if !dockLabel.isHidden { dockLabel.isHidden = true }
            return
        }
        if dockLabel.text != state.text { dockLabel.text = state.text }
        dockLabel.textColor = state.failed ? UIColor.white : UIColor.white.withAlphaComponent(0.92)
        dockLabel.backgroundColor = state.failed
            ? UIColor(red: 0.60, green: 0.12, blue: 0.12, alpha: 0.82)
            : UIColor.black.withAlphaComponent(0.45)
        dockLabel.isHidden = false
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

/// One tappable line in the in-HUD panel. UIControl + target/action, for the
/// same reason the panel exists: it works without a view controller.
private final class HUDPanelRow: UIControl {
    var action: (() -> Void)?

    private let rowBackground = UIColor.white.withAlphaComponent(0.06)
    private let rowHighlight = UIColor.white.withAlphaComponent(0.16)

    init(title: String, detail: String?, selected: Bool,
         destructive: Bool, enabled: Bool) {
        super.init(frame: .zero)
        backgroundColor = rowBackground
        layer.cornerRadius = 10
        isUserInteractionEnabled = enabled
        alpha = enabled ? 1 : 0.45
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        if selected { accessibilityTraits.insert(.selected) }

        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = destructive
            ? UIColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1)
            : .white
        titleLabel.numberOfLines = 0
        titleLabel.text = title

        let labels = UIStackView(arrangedSubviews: [titleLabel])
        labels.axis = .vertical
        labels.spacing = 2
        if let detail, !detail.isEmpty {
            let detailLabel = UILabel()
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = UIColor.white.withAlphaComponent(0.55)
            detailLabel.numberOfLines = 0
            detailLabel.text = detail
            labels.addArrangedSubview(detailLabel)
        }

        let check = UILabel()
        check.font = .systemFont(ofSize: 16, weight: .semibold)
        check.textColor = UIColor(red: 0.35, green: 0.85, blue: 0.5, alpha: 1)
        check.text = selected ? "✓" : ""
        check.textAlignment = .center
        check.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let content = UIStackView(arrangedSubviews: [labels, check])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 8
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? rowHighlight : rowBackground }
    }

    @objc private func tapped() {
        action?()
    }
}

/// A keycap that posts a real virtual key down/up pair while held.
final class HUDKeyButton: UIButton {
    private let vk: Int32
    private var keyDown = false
    private static let idleColor = UIColor.black.withAlphaComponent(0.45)
    private static let heldColor = UIColor.white.withAlphaComponent(0.35)

    init(label: String, vk: Int32, width: CGFloat? = nil, height: CGFloat = 40, autoLayout: Bool = true) {
        self.vk = vk
        super.init(frame: .zero)
        setTitle(label, for: .normal)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        backgroundColor = Self.idleColor
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        if autoLayout {
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: width ?? (label.count > 1 ? 58 : 46)),
                heightAnchor.constraint(equalToConstant: height),
            ])
        }
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
