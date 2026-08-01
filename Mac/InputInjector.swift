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
            self?.handleTouchLocked(phase: phase, x: x, y: y)
        }
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    /// Scroll events take points, so convert via the display's pixel scale.
    func handleScroll(dx: Double, dy: Double) {
        queue.async { [weak self] in
            guard let self else { return }
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

    /// Cancel any held button and put the cursor back on the Mac.
    func forceRelease() {
        queue.async { [weak self] in
            self?.forceReleaseLocked(restoreCursor: true)
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

    private func forceReleaseLocked(restoreCursor: Bool) {
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        if isDown {
            let bounds = CGDisplayBounds(displayID)
            let point = CGEvent(source: nil)?.location
                ?? CGPoint(x: bounds.midX, y: bounds.midY)
            postMouse(.leftMouseUp, at: point)
            isDown = false
        }
        if restoreCursor {
            restoreCursorSoon()
        }
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
