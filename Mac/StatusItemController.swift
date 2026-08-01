import AppKit
import SwiftUI
import Sparkle

/// Menu-bar icon that opens the original **box panel** (Form with option chips),
/// not a hierarchical NSMenu.
///
/// Click the status item → floating panel with Mode / Quality / Audio boxes.
/// No Dock icon (`LSUIElement` + accessory). Panel is a real `NSPanel` so it
/// does not rebuild/blank the way SwiftUI `MenuBarExtra` did while streaming.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private weak var updater: SPUStandardUpdaterController?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func install(updater: SPUStandardUpdaterController) {
        self.updater = updater
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                   accessibilityDescription: "OpenDisplay")
            button.image?.isTemplate = true
            button.toolTip = "OpenDisplay (Android)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // Left click only — no menu attached.
            button.sendAction(on: [.leftMouseUp])
        }
        statusItem = item
        updateIcon(running: SenderController.shared.running)
        Log.info("StatusItem: box panel control installed")
    }

    func updateIcon(running: Bool) {
        let name = running ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle"
        statusItem?.button?.image = NSImage(systemSymbolName: name,
                                            accessibilityDescription: "OpenDisplay")
        statusItem?.button?.image?.isTemplate = true
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        pauseTabletInjection()
        if panel == nil {
            buildPanel()
        }
        positionPanelNearStatusItem()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installClickAwayMonitor()
        updateIcon(running: SenderController.shared.running)
        Log.info("StatusItem: panel shown")
    }

    func closePanel() {
        removeClickAwayMonitor()
        panel?.orderOut(nil)
        InputInjector.noteMacControl(seconds: 1.0)
        InputInjector.injectionPaused = false
        SenderController.shared.setControlPanelOpen(false)
        Log.info("StatusItem: panel closed")
    }

    // MARK: - Build panel (original ContentView box layout)

    private func buildPanel() {
        let root = ContentView(controller: SenderController.shared, updater: updater)
            .frame(width: 440, height: 560)

        let hosting = NSHostingController(rootView: root)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "OpenDisplay"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.backgroundColor = .windowBackgroundColor
        p.isOpaque = true
        p.hasShadow = true
        p.contentViewController = hosting
        p.delegate = self
        panel = p
    }

    private func positionPanelNearStatusItem() {
        guard let panel, let button = statusItem?.button,
              let buttonWindow = button.window else {
            panel?.center()
            return
        }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        // Place panel below the status item, right-aligned to the icon.
        var origin = NSPoint(
            x: screenRect.maxX - panel.frame.width,
            y: screenRect.minY - panel.frame.height - 6
        )
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            if origin.y < visible.minY {
                origin.y = screenRect.maxY + 6
            }
        }
        panel.setFrameOrigin(origin)
    }

    private func pauseTabletInjection() {
        InputInjector.injectionPaused = true
        InputInjector.noteMacControl(seconds: 600)
        SenderController.shared.setControlPanelOpen(true)
        for session in SenderController.shared.sessions {
            session.sender.releaseInjectedPointer(restoreCursor: false, postEvents: false)
        }
    }

    /// Close when user clicks outside the panel (menu-bar popover behaviour).
    private func installClickAwayMonitor() {
        removeClickAwayMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.pauseTabletInjection()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let loc = NSEvent.mouseLocation
            if !panel.frame.contains(loc) {
                // Don't close if clicking the status item (toggle handles that).
                if let button = self.statusItem?.button,
                   let win = button.window {
                    let b = win.convertToScreen(button.convert(button.bounds, to: nil))
                    if b.contains(loc) { return }
                }
                DispatchQueue.main.async { self.closePanel() }
            }
        }
    }

    private func removeClickAwayMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
}

extension StatusItemController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        removeClickAwayMonitor()
        InputInjector.injectionPaused = false
        SenderController.shared.setControlPanelOpen(false)
    }
}
