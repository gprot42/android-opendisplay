import CoreGraphics
import AppKit

/// Turns normalized touch coordinates from the phone into mouse events on a
/// target display. Touch semantics: finger down = left button down, finger
/// move = drag, finger up = button up — i.e. the phone acts as a touchscreen.
///
/// Important for dual-use with the Mac keyboard/trackpad:
/// - Touches move the system cursor onto the virtual display (required for
///   clicks to hit windows there).
/// - On finger-up (or idle timeout) we **restore the cursor** to where it was
///   on the Mac so the user can immediately click iTerm2 / Dock again.
/// - A stuck finger-down (lost `ended` after disconnect) auto-releases so
///   the Mac is not left in a permanent drag that blocks selection.
final class InputInjector {

    /// When true, all injectors ignore tablet touches (OpenDisplay control
    /// panel is open). Prevents synthetic mouse events from cancelling clicks
    /// on our own UI. Must only be cleared when the settings window closes —
    /// never from SwiftUI onDisappear (view rebuilds mid-stream).
    static var injectionPaused = false

    /// Until this time, ignore tablet input so Mac trackpad/keyboard wins.
    private static var macControlUntil = Date.distantPast
    private static let macControlLock = NSLock()

    /// Call when the user moves/clicks/types on the Mac.
    static func noteMacControl(seconds: TimeInterval = 1.5) {
        macControlLock.lock()
        macControlUntil = Date().addingTimeInterval(seconds)
        macControlLock.unlock()
    }

    private static var macControlActive: Bool {
        macControlLock.lock()
        defer { macControlLock.unlock() }
        return Date() < macControlUntil
    }

    private let displayID: CGDirectDisplayID
    private var isDown = false
    // A real event source (vs nil) plus clickState=1 below: menu tracking
    // treats sourceless/zero-click synthetic clicks as malformed — menus
    // open but their tracking session breaks, leaving zombie menu windows
    // composited on the display (visible in the stream, unclickable).
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Cursor location before the current touch gesture (Mac trackpad spot).
    private var cursorBeforeTouch: CGPoint?
    private var lastTouchAt = Date.distantPast
    private var releaseWorkItem: DispatchWorkItem?
    /// How long after the last touch event we force mouse-up + cursor restore.
    private let idleReleaseSeconds: TimeInterval = 0.35
    private let queue = DispatchQueue(label: "opendisplay.input")

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    /// x/y are normalized [0,1] in video space (origin top-left).
    func handleTouch(phase: String, x: Double, y: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            if Self.injectionPaused {
                // Settings panel open: drop everything, no synthetic events.
                // Posting mouseUp here was cancelling real trackpad clicks.
                self.clearCaptureStateLocked()
                return
            }
            if Self.macControlActive || Self.pointerIsOverOurWindows() {
                // User is on the Mac / our UI — release any held tablet drag,
                // but only post a mouse-up if we actually held the button
                // (avoid cancelling a real click when isDown is already false).
                if self.isDown {
                    self.forceReleaseLocked(restoreCursor: false, postEvents: true)
                } else {
                    self.clearCaptureStateLocked()
                }
                return
            }
            self.handleTouchLocked(phase: phase, x: x, y: y)
        }
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    /// Scroll events take points, so convert via the display's pixel scale.
    func handleScroll(dx: Double, dy: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            if Self.injectionPaused || Self.macControlActive || Self.pointerIsOverOurWindows() {
                return
            }
            self.lastTouchAt = Date()
            self.scheduleIdleRelease()
            let bounds = CGDisplayBounds(self.displayID)
            let scale = bounds.width > 0 ? Double(CGDisplayPixelsWide(self.displayID)) / bounds.width : 2
            guard let event = CGEvent(scrollWheelEvent2Source: self.source, units: .pixel,
                                      wheelCount: 2,
                                      wheel1: Int32((dy / scale).rounded()),
                                      wheel2: Int32((dx / scale).rounded()),
                                      wheel3: 0) else { return }
            event.post(tap: .cghidEventTap)
        }
    }

    /// True when the system pointer is over any OpenDisplay window (menu panel).
    private static func pointerIsOverOurWindows() -> Bool {
        // NSEvent.mouseLocation is bottom-left Cocoa coords (same as NSWindow.frame).
        let mouse = NSEvent.mouseLocation
        for w in NSApp.windows where w.isVisible && !w.isMiniaturized {
            // Inflate slightly so the title bar / edges still count.
            if w.frame.insetBy(dx: -8, dy: -8).contains(mouse) {
                return true
            }
        }
        return false
    }

    /// True while a tablet finger is held (or a stuck down is pending idle release).
    var hasActiveCapture: Bool {
        queue.sync { isDown || cursorBeforeTouch != nil }
    }

    /// Cancel any held button. Optionally restore the pre-touch cursor.
    /// Use `restoreCursor: false` when opening our control panel so we do not
    /// yank the pointer away from the menu the user just clicked.
    ///
    /// `postEvents: false` clears local capture state without synthesizing a
    /// mouse-up — required while our settings UI is open, because a synthetic
    /// up cancels the real trackpad click mid-tracking.
    func forceRelease(restoreCursor: Bool = true, postEvents: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isDown || self.cursorBeforeTouch != nil else { return }
            self.forceReleaseLocked(restoreCursor: restoreCursor, postEvents: postEvents)
        }
    }

    // MARK: - Private

    private func handleTouchLocked(phase: String, x: Double, y: Double) {
        lastTouchAt = Date()
        scheduleIdleRelease()

        let bounds = CGDisplayBounds(displayID)   // global CG coords, y-down
        let point = CGPoint(
            x: bounds.origin.x + x * bounds.width,
            y: bounds.origin.y + y * bounds.height
        )

        let type: CGEventType
        switch phase {
        case "began":
            // New gesture: remember where the Mac cursor was.
            if !isDown {
                cursorBeforeTouch = CGEvent(source: nil)?.location
            } else {
                // Lost a prior `ended` — clear stuck drag first.
                postMouse(.leftMouseUp, at: point)
            }
            type = .leftMouseDown
            isDown = true
        case "moved":
            type = isDown ? .leftMouseDragged : .mouseMoved
        case "ended", "cancelled":
            guard isDown else {
                // Still restore cursor if we only saw moves.
                restoreCursorSoon()
                return
            }
            type = .leftMouseUp
            isDown = false
        default:
            return
        }

        postMouse(type, at: point)

        if phase == "ended" || phase == "cancelled" {
            restoreCursorSoon()
        }
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func scheduleIdleRelease() {
        releaseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard Date().timeIntervalSince(self.lastTouchAt) >= self.idleReleaseSeconds - 0.02 else { return }
                if self.isDown {
                    Log.info("InputInjector: idle timeout — releasing stuck mouse button")
                }
                self.forceReleaseLocked(restoreCursor: true)
            }
        }
        releaseWorkItem = work
        queue.asyncAfter(deadline: .now() + idleReleaseSeconds, execute: work)
    }

    private func forceReleaseLocked(restoreCursor: Bool, postEvents: Bool = true) {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        if isDown {
            if postEvents {
                // Mouse-up at the *current* location only — never warp first.
                let point = CGEvent(source: nil)?.location
                    ?? CGPoint(x: CGDisplayBounds(displayID).midX,
                               y: CGDisplayBounds(displayID).midY)
                postMouse(.leftMouseUp, at: point)
            }
            isDown = false
        }
        if restoreCursor {
            restoreCursorSoon()
        } else {
            // Discard saved point without moving the cursor (UI is in use).
            cursorBeforeTouch = nil
        }
    }

    /// Drop capture bookkeeping without synthesizing HID events.
    private func clearCaptureStateLocked() {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        isDown = false
        cursorBeforeTouch = nil
    }

    private func restoreCursorSoon() {
        guard let saved = cursorBeforeTouch else { return }
        cursorBeforeTouch = nil
        // Next runloop: after the synthetic up is processed.
        DispatchQueue.main.async {
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }
    }
}
