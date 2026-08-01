import AppKit
import ApplicationServices
import CoreGraphics

/// Finds windows stranded on an OpenDisplay virtual screen (or in limbo
/// after the display moved/was removed) and parks them on the main Mac
/// display so they are visible again.
///
/// Common failure: we re-assert Left/Right placement for a few seconds after
/// connect. If the user already dragged a window onto the tablet while
/// WindowServer still had it on the wrong side, absolute window coords no
/// longer match any display — the window “vanishes.” Same when the virtual
/// display is torn down mid-session.
enum WindowRecovery {

    /// OpenDisplay virtual displays use vendor "PC" / product "OS".
    static func isOpenDisplayVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x5043 && CGDisplayModelNumber(id) == 0x4F53
    }

    /// True when the system pointer is over a real Mac display (not an
    /// OpenDisplay virtual panel). Used to decide whether Dock / Cmd+Tab
    /// should pull an app back from the tablet.
    static func pointerIsOnPhysicalDisplay() -> Bool {
        guard let loc = CGEvent(source: nil)?.location else { return true }
        let displays = activeDisplays()
        var onPhysical = false
        var onVirtual = false
        for id in displays {
            let b = CGDisplayBounds(id).insetBy(dx: -8, dy: -8)
            guard b.contains(loc) else { continue }
            if isOpenDisplayVirtual(id) { onVirtual = true }
            else { onPhysical = true }
        }
        // Prefer physical when the pointer straddles a seam.
        if onPhysical { return true }
        if onVirtual { return false }
        return true
    }

    /// Move windows whose center sits on `displayID` (or off every active
    /// display, if `includeOffScreen`) onto the main screen. Returns count.
    /// Pass `processID` to limit to one app (Dock / Cmd+Tab bring-back).
    @discardableResult
    @MainActor
    static func retrieveWindows(fromDisplay displayID: CGDirectDisplayID? = nil,
                                includeOffScreen: Bool = true,
                                processID: pid_t? = nil) -> Int {
        guard AXIsProcessTrusted() else {
            Log.info("WindowRecovery: Accessibility required to move windows")
            return 0
        }

        let displays = activeDisplays()
        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        guard mainBounds.width > 1, mainBounds.height > 1 else { return 0 }

        var targetVirtual: Set<CGDirectDisplayID> = []
        if let displayID {
            targetVirtual.insert(displayID)
        } else {
            for id in displays where isOpenDisplayVirtual(id) {
                targetVirtual.insert(id)
            }
        }
        // Nothing to do if there is no virtual panel and we aren't sweeping
        // off-screen windows.
        if targetVirtual.isEmpty && !includeOffScreen { return 0 }

        var moved = 0
        let selfPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            if pid == selfPID { continue }
            if let processID, pid != processID { continue }
            if app.bundleIdentifier?.contains("opensidecar") == true { continue }

            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for win in windows {
                guard let pos = axPoint(win), let size = axSize(win),
                      size.width > 100, size.height > 60 else { continue }
                let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)

                var onTargetVirtual = false
                var onAny = false
                for id in displays {
                    // Generous inset: title bars near the edge still count.
                    let b = CGDisplayBounds(id).insetBy(dx: -48, dy: -48)
                    guard b.contains(center) else { continue }
                    onAny = true
                    if targetVirtual.contains(id) { onTargetVirtual = true }
                }

                let shouldMove = onTargetVirtual || (includeOffScreen && !onAny)
                guard shouldMove else { continue }

                placeOnMain(win, size: size, mainBounds: mainBounds)
                moved += 1
                Log.info("WindowRecovery: moved \(app.localizedName ?? "app") "
                    + "\(Int(size.width))x\(Int(size.height)) @(\(Int(pos.x)),\(Int(pos.y))) → main")
            }
        }
        if moved > 0 {
            Log.info("WindowRecovery: retrieved \(moved) window(s)")
        }
        return moved
    }

    /// Park the system pointer on the main display (call after attaching a
    /// virtual panel so the cursor isn’t stranded off-screen to the left).
    static func warpPointerToMainDisplay() {
        let mainID = CGMainDisplayID()
        let b = CGDisplayBounds(mainID)
        guard b.width > 1, b.height > 1 else { return }
        let target = CGPoint(x: b.midX, y: b.midY)
        if let loc = CGEvent(source: nil)?.location, b.insetBy(dx: -20, dy: -20).contains(loc) {
            return // already on main
        }
        CGWarpMouseCursorPosition(target)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        Log.info("WindowRecovery: warped pointer to main display")
    }

    /// After a virtual display origin change, translate windows that were on
    /// the old bounds so they stay on the panel (prevents limbo windows).
    @MainActor
    static func translateWindows(from oldBounds: CGRect, to newBounds: CGRect) {
        guard AXIsProcessTrusted() else { return }
        let dx = newBounds.minX - oldBounds.minX
        let dy = newBounds.minY - oldBounds.minY
        if abs(dx) < 1 && abs(dy) < 1 { return }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            if pid == selfPID { continue }
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }
            for win in windows {
                guard let pos = axPoint(win), let size = axSize(win),
                      size.width > 50, size.height > 40 else { continue }
                let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                // Was on the old panel (or in the gap created by the move).
                let wasOnOld = oldBounds.insetBy(dx: -24, dy: -24).contains(center)
                let nowOnNew = newBounds.insetBy(dx: -24, dy: -24).contains(center)
                guard wasOnOld, !nowOnNew else { continue }
                var newPos = CGPoint(x: pos.x + dx, y: pos.y + dy)
                // Clamp so the title bar stays reachable on the new panel.
                newPos.x = min(max(newPos.x, newBounds.minX), newBounds.maxX - min(size.width, newBounds.width))
                newPos.y = min(max(newPos.y, newBounds.minY + 22), newBounds.maxY - 80)
                setPoint(win, newPos)
            }
        }
        Log.info("WindowRecovery: translated windows by (\(Int(dx)),\(Int(dy))) with display move")
    }

    // MARK: - Private

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &list, &n)
        return Array(list.prefix(Int(n)))
    }

    private static func placeOnMain(_ win: AXUIElement, size: CGSize, mainBounds: CGRect) {
        let margin: CGFloat = 40
        let pos = CGPoint(x: mainBounds.minX + margin, y: mainBounds.minY + margin + 22)
        var newSize = CGSize(
            width: min(max(size.width, 320), mainBounds.width - margin * 2),
            height: min(max(size.height, 240), mainBounds.height - margin * 2 - 22)
        )
        setSize(win, newSize)
        setPoint(win, pos)
    }

    private static func axPoint(_ el: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    private static func axSize(_ el: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    private static func setPoint(_ el: AXUIElement, _ p: CGPoint) {
        var pt = p
        guard let v = AXValueCreate(.cgPoint, &pt) else { return }
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
    }

    private static func setSize(_ el: AXUIElement, _ s: CGSize) {
        var sz = s
        guard let v = AXValueCreate(.cgSize, &sz) else { return }
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
    }
}
