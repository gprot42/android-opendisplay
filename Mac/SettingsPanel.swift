import AppKit
import Sparkle

/// Pure AppKit settings window.
///
/// SwiftUI in this panel was unusable while streaming: every session/status
/// `@Published` tick rebuilt the view tree and cancelled in-flight button
/// presses. AppKit controls are stable. `NSSegmentedControl` also makes the
/// active choice obvious (system selected-segment chrome).
@MainActor
final class SettingsPanelController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var updater: SPUStandardUpdaterController?

    private var statusField: NSTextField!
    private var devicesField: NSTextField!
    private var modeControl: NSSegmentedControl!
    private var sideControl: NSSegmentedControl!
    private var sideCaption: NSTextField!
    private var qualityControl: NSSegmentedControl!
    private var qualityCaption: NSTextField!
    private var audioControl: NSSegmentedControl!
    private var audioCaption: NSTextField!
    private var modeCaption: NSTextField!
    private var connectButton: NSButton!
    private var disconnectButton: NSButton!
    private var retrieveButton: NSButton!

    private var refreshTimer: Timer?
    private var localMonitor: Any?
    /// Ignore programmatic segment writes while a control is tracking.
    private var userIsTracking = false

    var windowRef: NSWindow? { window }

    init(updater: SPUStandardUpdaterController?) {
        self.updater = updater
        super.init()
    }

    func show() {
        pauseTabletInjection()
        NSApp.setActivationPolicy(.regular)
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        syncFromModel()
        startRefreshTimer()
        installLocalMonitor()
        Log.info("SettingsPanel: shown (tablet input paused)")
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        removeLocalMonitor()
        SenderController.shared.setControlPanelOpen(false)
        if SenderController.shared.presentation != .dock {
            NSApp.setActivationPolicy(.accessory)
        }
        Log.info("SettingsPanel: closed (tablet input resumed)")
    }

    // MARK: - Build

    private func buildWindow() {
        let width: CGFloat = 420
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "OpenDisplay (Android)"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .normal
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.hidesOnDeactivate = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 560))
        let pad: CGFloat = 20
        let contentW = width - pad * 2
        var y: CGFloat = 560 - pad

        func place(_ view: NSView, height: CGFloat, gap: CGFloat = 10) {
            y -= height
            view.frame = NSRect(x: pad, y: y, width: contentW, height: height)
            root.addSubview(view)
            y -= gap
        }

        // Title
        let title = makeLabel("OpenDisplay (Android)", font: .boldSystemFont(ofSize: 16))
        place(title, height: 22, gap: 6)

        statusField = makeLabel("Idle", font: .systemFont(ofSize: 12))
        statusField.textColor = .secondaryLabelColor
        place(statusField, height: 16, gap: 4)

        devicesField = makeWrapping("Devices: none")
        place(devicesField, height: 40, gap: 14)

        // Connection
        place(makeSection("Connection"), height: 16, gap: 8)
        connectButton = makePush("Connect Android USB", #selector(connectAndroid))
        disconnectButton = makePush("Disconnect All", #selector(disconnectAll))
        let connRow = NSView(frame: .zero)
        connectButton.frame = NSRect(x: 0, y: 0, width: 190, height: 32)
        disconnectButton.frame = NSRect(x: 200, y: 0, width: 140, height: 32)
        connRow.addSubview(connectButton)
        connRow.addSubview(disconnectButton)
        place(connRow, height: 32, gap: 8)

        retrieveButton = makePush("Retrieve Windows to Mac", #selector(retrieveWindows))
        place(retrieveButton, height: 28, gap: 16)

        // Mode
        place(makeSection("Mode"), height: 16, gap: 6)
        modeControl = makeSegments(["Extend", "Mirror"], #selector(modeChanged(_:)))
        place(modeControl, height: 28, gap: 4)
        modeCaption = makeCaption("…")
        place(modeCaption, height: 32, gap: 12)

        // Position
        place(makeSection("Screen position (Extend)"), height: 16, gap: 6)
        sideControl = makeSegments(["Left of Mac", "Right of Mac"], #selector(sideChanged(_:)))
        place(sideControl, height: 28, gap: 4)
        sideCaption = makeCaption("…")
        place(sideCaption, height: 28, gap: 12)

        // Quality
        place(makeSection("Quality"), height: 16, gap: 6)
        qualityControl = makeSegments(["Best", "Balanced", "Fast"], #selector(qualityChanged(_:)))
        place(qualityControl, height: 28, gap: 4)
        qualityCaption = makeCaption("…")
        place(qualityCaption, height: 32, gap: 12)

        // Audio
        place(makeSection("Play audio on"), height: 16, gap: 6)
        audioControl = makeSegments(["Tablet", "This Mac"], #selector(audioChanged(_:)))
        place(audioControl, height: 28, gap: 4)
        audioCaption = makeCaption("…")
        place(audioCaption, height: 32, gap: 14)

        // Permissions + quit
        let screenBtn = makePush("Screen Recording…", #selector(openScreenRecording))
        let accessBtn = makePush("Accessibility…", #selector(openAccessibility))
        let quitBtn = makePush("Quit", #selector(quitApp))
        let permRow = NSView(frame: .zero)
        screenBtn.frame = NSRect(x: 0, y: 0, width: 150, height: 28)
        accessBtn.frame = NSRect(x: 158, y: 0, width: 130, height: 28)
        quitBtn.frame = NSRect(x: 296, y: 0, width: 70, height: 28)
        permRow.addSubview(screenBtn)
        permRow.addSubview(accessBtn)
        permRow.addSubview(quitBtn)
        place(permRow, height: 28, gap: 8)

        // Fit window to used content (y is bottom padding remaining).
        let usedHeight = 560 - y + pad
        root.frame = NSRect(x: 0, y: 0, width: width, height: usedHeight)
        // Re-place was from top of 560 — shift all subviews up if usedHeight differs.
        if usedHeight != 560 {
            let dy = usedHeight - 560
            for sub in root.subviews {
                sub.frame.origin.y += dy
            }
        }

        w.contentView = root
        w.setContentSize(NSSize(width: width, height: usedHeight))
        w.center()
        window = w
    }

    // MARK: - Control factories

    private func makeLabel(_ text: String, font: NSFont) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = font
        return t
    }

    private func makeSection(_ text: String) -> NSTextField {
        makeLabel(text, font: .boldSystemFont(ofSize: 13))
    }

    private func makeCaption(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func makeWrapping(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 12)
        return t
    }

    private func makePush(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.setButtonType(.momentaryPushIn)
        return b
    }

    private func makeSegments(_ labels: [String], _ action: Selector) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        c.segmentDistribution = .fillEqually
        c.segmentStyle = .rounded
        // selectedSegment stays highlighted by AppKit — clear active choice.
        return c
    }

    // MARK: - Sync (model → UI). Never while user is clicking.

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncFromModel() }
        }
    }

    private func syncFromModel() {
        if window?.isVisible == true {
            InputInjector.injectionPaused = true
        }
        // Never rewrite segment selection while the mouse is down or a segment
        // is mid-track — that was making options impossible to select.
        if NSEvent.pressedMouseButtons != 0 || userIsTracking {
            syncStatusOnly()
            return
        }

        let c = SenderController.shared
        setSegment(modeControl, c.mode == .extend ? 0 : 1)
        setSegment(sideControl, c.displaySide == .left ? 0 : 1)
        sideControl.isEnabled = c.mode == .extend
        if let qi = StreamQuality.allCases.firstIndex(of: c.quality) {
            setSegment(qualityControl, qi)
        }
        setSegment(audioControl, c.audioOutput == .tablet ? 0 : 1)

        modeCaption.stringValue = c.mode == .extend
            ? "Tablet is an extra screen. Drag windows onto it."
            : "Tablet shows a copy of this Mac’s main display."
        sideCaption.stringValue = c.displaySide == .left
            ? "Virtual display sits to the left of the Mac."
            : "Virtual display sits to the right of the Mac."
        qualityCaption.stringValue = c.quality.explanation
        audioCaption.stringValue = c.audioOutput.explanation

        connectButton.isEnabled = c.androidUsbAvailable
        disconnectButton.isEnabled = !c.sessions.isEmpty
        retrieveButton.isEnabled = c.sessions.contains { $0.sender.canHostWindows }

        syncStatusOnly()
    }

    private func syncStatusOnly() {
        let c = SenderController.shared
        if c.sessions.isEmpty {
            statusField.stringValue = c.androidUsbAvailable
                ? "Idle — \(c.androidUsbLabel) available"
                : "Idle — no Android USB device"
            devicesField.stringValue = "Devices: none connected"
        } else {
            statusField.stringValue = "\(c.sessions.count) session(s) active"
            devicesField.stringValue = c.sessions
                .map { "• \($0.name): \($0.status)" }
                .joined(separator: "\n")
        }
    }

    private func setSegment(_ control: NSSegmentedControl?, _ index: Int) {
        guard let control, control.selectedSegment != index else { return }
        control.selectedSegment = index
    }

    // MARK: - Injection pause

    private func installLocalMonitor() {
        removeLocalMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                self.userIsTracking = true
            } else if event.type == .leftMouseUp {
                self.userIsTracking = false
            }
            self.pauseTabletInjection()
            return event
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        userIsTracking = false
    }

    private func pauseTabletInjection() {
        InputInjector.injectionPaused = true
        InputInjector.noteMacControl(seconds: 600)
        SenderController.shared.setControlPanelOpen(true)
        for session in SenderController.shared.sessions {
            session.sender.releaseInjectedPointer(restoreCursor: false, postEvents: false)
        }
    }

    // MARK: - Actions

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        userIsTracking = false
        pauseTabletInjection()
        let next: CaptureMode = sender.selectedSegment == 0 ? .extend : .mirror
        let c = SenderController.shared
        sideControl.isEnabled = next == .extend
        modeCaption.stringValue = next == .extend
            ? "Tablet is an extra screen. Drag windows onto it."
            : "Tablet shows a copy of this Mac’s main display."
        guard c.mode != next else { return }
        c.mode = next
        c.scheduleRestartAll()
        Log.info("SettingsPanel: mode → \(next.rawValue)")
    }

    @objc private func sideChanged(_ sender: NSSegmentedControl) {
        userIsTracking = false
        pauseTabletInjection()
        let next: DisplaySide = sender.selectedSegment == 0 ? .left : .right
        let c = SenderController.shared
        sideCaption.stringValue = next == .left
            ? "Virtual display sits to the left of the Mac."
            : "Virtual display sits to the right of the Mac."
        guard c.displaySide != next else { return }
        c.displaySide = next
        c.scheduleRestartAll()
        Log.info("SettingsPanel: side → \(next.rawValue)")
    }

    @objc private func qualityChanged(_ sender: NSSegmentedControl) {
        userIsTracking = false
        pauseTabletInjection()
        let idx = sender.selectedSegment
        guard idx >= 0, idx < StreamQuality.allCases.count else { return }
        let next = StreamQuality.allCases[idx]
        let c = SenderController.shared
        qualityCaption.stringValue = next.explanation
        guard c.quality != next else { return }
        c.quality = next
        c.scheduleRestartAll()
        Log.info("SettingsPanel: quality → \(next.rawValue)")
    }

    @objc private func audioChanged(_ sender: NSSegmentedControl) {
        userIsTracking = false
        pauseTabletInjection()
        let next: AudioOutput = sender.selectedSegment == 0 ? .tablet : .mac
        let c = SenderController.shared
        audioCaption.stringValue = next.explanation
        guard c.audioOutput != next else { return }
        c.audioOutput = next
        c.scheduleRestartAll()
        Log.info("SettingsPanel: audio → \(next.rawValue)")
    }

    @objc private func connectAndroid() {
        pauseTabletInjection()
        SenderController.shared.connect(to: .androidUsb, userInitiated: true)
        Log.info("SettingsPanel: connect Android USB")
        syncFromModel()
    }

    @objc private func disconnectAll() {
        pauseTabletInjection()
        SenderController.shared.disconnectAll()
        Log.info("SettingsPanel: disconnect all")
        syncFromModel()
    }

    @objc private func retrieveWindows() {
        pauseTabletInjection()
        let n = SenderController.shared.retrieveAllWindowsToMac()
        Log.info("SettingsPanel: retrieved \(n) window(s)")
        syncFromModel()
    }

    @objc private func openScreenRecording() {
        PermissionMonitor().requestScreenRecording()
    }

    @objc private func openAccessibility() {
        PermissionMonitor().requestAccessibility()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
