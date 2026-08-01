import AppKit
import CoreGraphics

/// Full-screen solid backdrop on the virtual display, sitting at desktop
/// level under normal app windows.
///
/// CGVirtualDisplay desktops often leave unpainted / stale framebuffer
/// regions when a window is dragged off — the tablet then freezes on a
/// partial frame that still shows the title bar or app name. A real window
/// under everything forces WindowServer to composite a clean fill, and
/// [nudge] dirties the display so ScreenCaptureKit re-samples after moves.
@MainActor
enum DesktopUnderlay {
    private static var windows: [CGDirectDisplayID: NSWindow] = [:]
    private static var fillViews: [CGDirectDisplayID: NSView] = [:]

    static func show(on displayID: CGDirectDisplayID) {
        hide(on: displayID)
        Task { @MainActor in
            for _ in 0..<15 {
                if let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
                }) {
                    let w = NSWindow(
                        contentRect: screen.frame,
                        styleMask: [.borderless],
                        backing: .buffered,
                        defer: false,
                        screen: screen
                    )
                    // Below normal apps, above/at desktop wallpaper so empty
                    // regions always have real pixels (not leftover window
                    // content from the private virtual-display compositor).
                    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                    w.isOpaque = true
                    w.backgroundColor = fillColor(phase: 0)
                    w.hasShadow = false
                    w.ignoresMouseEvents = true
                    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                    w.isReleasedWhenClosed = false

                    let fill = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                    fill.wantsLayer = true
                    fill.layer?.backgroundColor = fillColor(phase: 0).cgColor
                    fill.autoresizingMask = [.width, .height]
                    w.contentView = fill

                    w.setFrame(screen.frame, display: true)
                    w.orderFrontRegardless()
                    windows[displayID] = w
                    fillViews[displayID] = fill
                    Log.info("desktop underlay shown on display \(displayID)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            Log.info("desktop underlay: screen for display \(displayID) never appeared")
        }
    }

    static func hide(on displayID: CGDirectDisplayID) {
        fillViews.removeValue(forKey: displayID)
        if let w = windows.removeValue(forKey: displayID) {
            w.orderOut(nil)
            w.close()
        }
    }

    /// Tiny, brief color tick so WindowServer + ScreenCaptureKit re-sample
    /// the display after a window leaves — without a visible flash.
    static func nudge(on displayID: CGDirectDisplayID) {
        guard let fill = fillViews[displayID], let w = windows[displayID] else { return }
        // Keep the window covering the current screen bounds (arrangement
        // restore can move the virtual display after we first showed).
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            w.setFrame(screen.frame, display: false)
        }
        fill.layer?.backgroundColor = fillColor(phase: 1).cgColor
        // Snap back on the next runloop turn — enough dirtying for SCK,
        // not long enough to notice on the tablet.
        DispatchQueue.main.async {
            fill.layer?.backgroundColor = fillColor(phase: 0).cgColor
        }
    }

    /// Near-black desktop fill. Phase 1 is one 8-bit step brighter for nudge.
    private static func fillColor(phase: Int) -> NSColor {
        let white: CGFloat = phase == 0 ? 0.12 : 0.125
        return NSColor(calibratedWhite: white, alpha: 1)
    }
}
