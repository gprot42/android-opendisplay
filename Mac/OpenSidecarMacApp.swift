import SwiftUI
import Network
import Combine
import Sparkle

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .background: return "Background only"
        }
    }
}

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Required Scene for SwiftUI App lifecycle. Real UI is the AppKit
        // NSStatusItem menu (StatusItemController) — SwiftUI MenuBarExtra
        // rebuilt empty/unusable while streaming status published every second.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Local/dev builds ship `MARKETING_VERSION` 0.0.0 (see project.yml).
    /// Those must not poll the public OpenDisplay appcast — Sparkle would
    /// offer upstream 1.x and replace this Android-fork build.
    private static var isLocalDevBuild: Bool {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        return v == "0.0.0"
    }

    // Sparkle only for non-dev builds. `startingUpdater: false` for 0.0.0 so
    // we never auto-prompt "1.14.0 available — you have 0.0.0".
    let updater = SPUStandardUpdaterController(
        startingUpdater: !AppDelegate.isLocalDevBuild,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent only — no Dock icon, no floating settings window.
        _ = SenderController.shared
        SenderController.shared.presentation = .menuBar
        NSApp.setActivationPolicy(.accessory)

        if Self.isLocalDevBuild {
            updater.updater.automaticallyChecksForUpdates = false
            Log.info("Sparkle: disabled (local build 0.0.0 — ignore upstream appcast)")
        }

        StatusItemController.shared.install(updater: updater)
        Log.info("OpenDisplay launched (menu bar → box panel)")
    }

    // Spotlight / Finder re-open: show the control panel again.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        StatusItemController.shared.showPanel()
        return false
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour
    case androidUsb                   // Android cable via adb forward → 127.0.0.1

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        case .androidUsb: return "android-usb"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    let sender: MacSender

    @Published var status = "Starting…"
    @Published var framesSent = 0
    @Published var mbps = 0.0
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?

    var transportLabel: String {
        switch target {
        case .androidUsb: return "USB (Android)"
        case .usb: return onUSB ? "USB" : "WiFi"
        case .wifi: return onUSB ? "USB" : "WiFi"
        }
    }

    init(id: String, target: ConnectionTarget, name: String, sender: MacSender) {
        self.id = id
        self.target = target
        self.name = name
        self.sender = sender
        switch target {
        case .usb(let udid):
            onUSB = true
            usbUDID = udid
        case .androidUsb:
            onUSB = true
            usbUDID = nil
        case .wifi:
            onUSB = false
        }
    }
}

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            // Menu-bar agent by default — only Dock mode shows a Dock icon.
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        }
    }

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    @Published var usbDevices: [UsbmuxDevice] = []
    /// adb-visible Android devices (for the Android USB row).
    @Published var androidUsbAvailable = false
    @Published var androidUsbLabel = "Android USB"
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works (see init).
    @Published var mode: CaptureMode = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-mode"), i + 1 < args.count,
           let m = CaptureMode(rawValue: args[i + 1]) {
            UserDefaults.standard.set(m.rawValue, forKey: "mode")
            return m
        }
        return CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend
    }() {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    /// Where system audio plays while streaming (default: device speakers).
    @Published var audioOutput =
        AudioOutput(rawValue: UserDefaults.standard.string(forKey: "audioOutput") ?? "") ?? .tablet {
        didSet {
            UserDefaults.standard.set(audioOutput.rawValue, forKey: "audioOutput")
            // Switching off tablet audio must always unsilence Mac speakers,
            // even if session teardown races the next connect.
            if audioOutput == .mac {
                SystemAudioMute.forceReleaseAll()
            }
        }
    }
    /// Place the virtual display left or right of the Mac main screen.
    @Published var displaySide = DisplayArrangement.preferredSide {
        didSet { DisplayArrangement.preferredSide = displaySide }
    }
    /// When true: focusing an app via Dock / Cmd+Tab / click pulls that
    /// app’s windows off the tablet back onto the Mac automatically.
    /// Default is **off** — windows stay on the tablet until Retrieve / Send.
    @Published var focusRetrieveEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "focusRetrieveEnabled") == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: "focusRetrieveEnabled")
    }() {
        didSet { UserDefaults.standard.set(focusRetrieveEnabled, forKey: "focusRetrieveEnabled") }
    }

    var running: Bool { !sessions.isEmpty }

    private var browser: NWBrowser?
    private var usbWatcher: UsbmuxDeviceWatcher?

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - USB devices connect on attach ("plug in and go") unless the user
    //    explicitly disconnected them once (usbDisabled).
    //  - Plugging the cable in while the device streams over WiFi migrates
    //    the live session onto USB; unplugging it fails over to WiFi when
    //    the device's service is visible — otherwise the session ends after
    //    the usual grace. Migrations swap only the socket (switchTransport):
    //    the virtual display survives, so no screen flash, no window
    //    reshuffle — the earlier no-switching policy existed because
    //    migration used to mean destroying and recreating the session.
    //  - WiFi devices the user connected before (wifiRemembered) reconnect
    //    in a short window at LAUNCH only — never mid-session.
    // `-autostart NO` disables all auto-connecting, including migrations.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    private var wifiRemembered = Set(UserDefaults.standard.stringArray(forKey: "wifiRemembered") ?? []) {
        didSet { UserDefaults.standard.set(Array(wifiRemembered), forKey: "wifiRemembered") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    // Bonjour usually reports devices before usbmuxd does — WiFi reconnects
    // wait out this window so a cabled device is dialed over USB first. The
    // deadline closes the window for good: a remembered WiFi device that
    // appears later was brought near the Mac mid-session, which is a user
    // action to confirm, not auto-grab.
    private var wifiAutoConnectArmed = false
    private let wifiAutoConnectDeadline = Date().addingTimeInterval(12)

    init() {
        Log.info("SenderController init")
        startBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            let detached = Set(self.usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
            self.usbDevices = devices
            self.failover(detachedUDIDs: detached)
            self.autoConnect()
        }
        startAndroidAdbPolling()
        startFocusWindowRetrieval()
        Log.info("SenderController: Android USB polling started")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.wifiAutoConnectArmed = true
            self.autoConnect()
        }
    }

    /// When the user focuses an app from the Mac (Dock / Cmd+Tab / click)
    /// while the pointer is on a real display, pull that app’s windows off
    /// the virtual tablet so they aren’t “lost” on the extended screen.
    private func startFocusWindowRetrieval() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                self.bringActivatedAppBackIfNeeded(note)
            }
        }
        // Prefer Mac control over tablet injection for a short window when
        // the user types or moves the trackpad — without posting synthetic
        // mouse-ups that cancel clicks in our own menu.
        var lastNote = Date.distantPast
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(lastNote) > 0.2 else { return }
            lastNote = now
            InputInjector.noteMacControl(seconds: 1.5)
            Task { @MainActor in
                for session in self.sessions where session.sender.hasInjectedPointerCapture {
                    session.sender.releaseInjectedPointer()
                }
            }
        }
    }

    /// Pause/resume tablet mouse injection while the control panel is open.
    func setControlPanelOpen(_ open: Bool) {
        InputInjector.injectionPaused = open
        if open {
            // Long window so tablet touches stay inert while the panel is up.
            InputInjector.noteMacControl(seconds: 600)
            // Clear capture state without synthesizing mouse-up (that cancels
            // real trackpad clicks on Mode / Audio / Quality buttons).
            for session in sessions {
                session.sender.releaseInjectedPointer(restoreCursor: false, postEvents: false)
            }
        }
    }

    @MainActor
    private func bringActivatedAppBackIfNeeded(_ note: Notification) {
        guard sessions.contains(where: { $0.sender.canHostWindows }) else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                ?? note.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication else {
            return
        }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        // Always clear a tablet-driven mouse capture when the user focuses
        // something from the Mac side (Dock / Cmd+Tab / click).
        for session in sessions {
            session.sender.releaseInjectedPointer()
        }

        // Optional: pull windows back to the Mac when the app is activated.
        guard focusRetrieveEnabled else { return }
        guard AXIsProcessTrusted() else { return }
        // Pull this app’s windows off the virtual tablet even if the cursor
        // is still stranded there — otherwise Cmd+Tab “selects” iTerm2 with
        // no visible window on the laptop screen.
        let n = WindowRecovery.retrieveWindows(
            fromDisplay: nil,
            includeOffScreen: true,
            processID: pid
        )
        if n > 0 {
            Log.info("FocusRetrieve: \(app.localizedName ?? "app") — \(n) window(s) → Mac")
            WindowRecovery.warpPointerToMainDisplay()
        }
    }

    /// Manual: pull every window off every virtual tablet onto the main Mac.
    @MainActor
    @discardableResult
    func retrieveAllWindowsToMac() -> Int {
        var total = 0
        for session in sessions where session.sender.canHostWindows {
            total += session.sender.retrieveWindowsToMac()
        }
        if total == 0 {
            // No live extend session — still sweep any leftover virtual / limbo.
            total = WindowRecovery.retrieveWindows(fromDisplay: nil, includeOffScreen: true)
        }
        return total
    }

    /// Poll adb / USB tether / cable presence for the Android USB row.
    /// Heavy work (`adb`, `ioreg`, `networksetup`) runs off the main actor so
    /// the menu-bar panel stays responsive.
    private func startAndroidAdbPolling() {
        Task.detached(priority: .utility) { [weak self] in
            Log.info("Android USB poll loop entered")
            while !Task.isCancelled {
                guard let controller = self else { return }
                let (portNum, androidSession): (UInt16?, Bool) = await MainActor.run {
                    (UInt16(controller.port),
                     controller.session(for: ConnectionTarget.androidUsb.sessionID) != nil)
                }
                Log.info("Android USB poll tick")

                // Discovery only first — never block the row on route/DNS fixups.
                // Inline (this task is already off the main actor) so we don't
                // nest another detached task that can stall scheduling.
                let serials = AndroidAdb.deviceSerials()
                let adbName = AndroidAdb.displayName()
                let tether = AndroidTether.isLikelyPresent()
                let tetherLabel = AndroidTether.displayName()
                // Skip ioreg when adb/tether already prove a device is present —
                // full USB tree dumps were a major hitch source.
                let cable: AndroidUsbCable.Device? = (serials.isEmpty && !tether)
                    ? AndroidUsbCable.primary()
                    : nil

                let available = tether || !serials.isEmpty || cable != nil
                let label: String = {
                    if !serials.isEmpty, let name = adbName { return name }
                    if tether { return tetherLabel ?? "Android USB (tether)" }
                    if let cable { return "\(cable.name) (USB · \(cable.shortModeHint))" }
                    return "Android USB"
                }()

                await MainActor.run {
                    let wasAvailable = controller.androidUsbAvailable
                    // Only publish when values change — force-assigning every
                    // 2s rebuilt the settings Form and killed picker clicks.
                    if controller.androidUsbAvailable != available {
                        controller.androidUsbAvailable = available
                    }
                    if controller.androidUsbLabel != label {
                        controller.androidUsbLabel = label
                    }
                    Log.info("Android USB poll: available=\(available) label=\(label) tether=\(tether) adb=\(serials.count) cable=\(cable?.name ?? "nil")")
                    // Cable / adb appeared or session missing: try auto-connect.
                    if available, !androidSession {
                        controller.autoConnect()
                    } else if available, !wasAvailable {
                        controller.autoConnect()
                    }
                }

                // Internet fixups + adb forward — separate so networksetup
                // never delays the device list. Keep the forward alive even
                // between sessions so the next dial is not refused.
                if available || androidSession {
                    let serialsCopy = serials
                    Task.detached(priority: .utility) {
                        if tether || cable != nil || androidSession {
                            _ = AndroidTether.preservePrimaryInternet()
                        }
                        if !serialsCopy.isEmpty, let portNum {
                            _ = AndroidAdb.ensureForward(devicePort: portNum)
                        }
                    }
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.discovered = Array(results)
                self.endSessionsWhoseServiceVanished()
                self.autoConnect()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        if let id = txtID(of: result), installIDByUDID[device.udid] == id { return true }
        if let name = serviceName(of: result), let usbName = device.name,
           usbName == name { return true }
        return false
    }

    /// The session (over either transport) already serving this USB device.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)") { return direct }
        return sessions.first { s in
            guard case .wifi(let result) = s.target else { return false }
            if let id = installIDByUDID[device.udid],
               s.deviceID == id || txtID(of: result) == id { return true }
            return serviceName(of: result) != nil && device.name == serviceName(of: result)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let name = serviceName(of: result), let direct = session(for: "wifi:\(name)") {
            return direct
        }
        return sessions.first { s in
            guard case .usb(let udid) = s.target else { return false }
            if let id = txtID(of: result), s.deviceID == id { return true }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }),
               sameDevice(result, device) { return true }
            // Browse results routinely lack their TXT record and the USB
            // device is gone after a failover — the service name is then
            // the only remaining link to the session.
            let name = serviceName(of: result)
            return name != nil && (name == s.wifiServiceName || name == s.name)
        }
    }

    // MARK: - Connection policy

    private func autoConnect() {
        guard autoConnectEnabled else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"), session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            if let covering = activeSession(coveringUSB: device) {
                // usbDisabled gates auto-connecting a device, not the
                // transport of a session the user deliberately has running —
                // however it was started, the cable is better: take it.
                upgradeToUSB(covering, device: device)
            } else if !usbDisabled.contains("usb:\(device.udid)") {
                connect(to: .usb(udid: device.udid))
            }
        }
        // Android USB: auto-dial when the cable/adb path is up and the user
        // has not explicitly disconnected. Survives brief RSTs without a
        // manual menu click after the session ends.
        let androidID = ConnectionTarget.androidUsb.sessionID
        if androidUsbAvailable,
           session(for: androidID) == nil,
           !usbDisabled.contains(androidID) {
            connect(to: .androidUsb)
        }
        guard wifiAutoConnectArmed, Date() < wifiAutoConnectDeadline else { return }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            if wifiRemembered.contains(target.sessionID),
               activeSession(coveringWiFi: result) == nil,
               !cabled(result) {
                connect(to: target)
            }
        }
    }

    /// An attached, auto-connectable USB device is (about to be) dialed over
    /// the cable — its WiFi service must not be grabbed in the launch race.
    private func cabled(_ result: NWBrowser.Result) -> Bool {
        usbDevices.contains {
            sameDevice(result, $0) && !usbDisabled.contains("usb:\($0.udid)")
        }
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB, let portNum = UInt16(port) else { return }
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.onUSB = true
        session.usbUDID = device.udid
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        session.sender.switchTransport(to: .usb(udid: device.udid, port: portNum))
    }

    /// Cable unplugged under a live session: fail over to the device's WiFi
    /// service if one is visible. Without one the session keeps its normal
    /// fate — retry over USB through the grace period, then end.
    private func failover(detachedUDIDs: Set<String>) {
        guard autoConnectEnabled, !detachedUDIDs.isEmpty else { return }
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, detachedUDIDs.contains(udid),
                  let result = wifiService(for: session) else { continue }
            Log.info("cable detached for \(session.id) — failing over to WiFi")
            session.onUSB = false
            session.wifiServiceName = serviceName(of: result)
            session.sender.switchTransport(to: .tcp(result.endpoint))
        }
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 8s: mDNS can drop for several seconds on Android OEM Wi‑Fi / during
    /// sleep-wake — only a withdrawal that persists counts. One-shot,
    /// guarded re-check, so overlapping browse events at worst repeat an
    /// idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. Keep the cable, drop the WiFi twin.
    private func dedupeSessions() {
        let usbSessionIDs = Set(sessions.compactMap { s -> String? in
            if case .usb = s.target { return s.deviceID }
            return nil
        })
        let cabledNames = Set(usbDevices.compactMap { device in
            session(for: "usb:\(device.udid)") != nil ? device.name : nil
        })
        for s in sessions {
            guard case .wifi(let result) = s.target else { continue }
            let duplicate = (s.deviceID.map { usbSessionIDs.contains($0) } ?? false)
                || (txtID(of: result).map { usbSessionIDs.contains($0) } ?? false)
                || (serviceName(of: result).map { cabledNames.contains($0) } ?? false)
            if duplicate {
                Log.info("two sessions for one device — keeping the cable, dropping \(s.id)")
                end(s)
            }
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            return udid == nil ? "Manual (\(host):\(port))" : "iPhone / iPad"
        case .wifi(let result):
            return serviceName(of: result) ?? "WiFi device"
        case .androidUsb:
            return AndroidAdb.displayName()
                ?? AndroidTether.displayName()
                ?? "Android USB"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        let id = target.sessionID
        guard session(for: id) == nil else { return }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        switch target {
        case .usb: usbDisabled.remove(id)
        case .wifi: wifiRemembered.insert(id)
        case .androidUsb: break
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!))
            } else {
                transport = .usb(udid: udid, port: portNum)
            }
        case .wifi(let result):
            transport = .tcp(result.endpoint)
        case .androidUsb:
            guard let portNum = UInt16(port) else { return }
            // Prefer adb when available: no USB tethering, so macOS never gets
            // a phone default route and Wi‑Fi/Ethernet keep working.
            // Fall back to USB tethering only when adb is unavailable; then
            // demote the tether default route so OpenDisplay uses the cable
            // without stealing Mac internet.
            if let hostPort = AndroidAdb.ensureForward(devicePort: portNum) {
                Log.info("Android USB: using adb forward → 127.0.0.1:\(hostPort) (preferred — no tether / no route impact)")
                // If the user also enabled USB tethering, still demote its
                // default route so Mac internet is not stuck on the phone.
                if AndroidTether.isLikelyPresent() {
                    _ = AndroidTether.preservePrimaryInternet()
                }
                transport = .tcp(.hostPort(host: "127.0.0.1",
                                           port: NWEndpoint.Port(rawValue: hostPort)!))
            } else if let peer = AndroidTether.resolvePeer(port: portNum) {
                let preserve = AndroidTether.preservePrimaryInternet()
                Log.info("Android USB: tether peer \(peer.host):\(portNum) via \(peer.interfaceName) src=\(peer.localHost) preserve=\(preserve)")
                transport = .tcp(
                    .hostPort(host: NWEndpoint.Host(peer.host),
                              port: NWEndpoint.Port(rawValue: portNum)!),
                    localHost: peer.localHost)
            } else {
                let adbN = AndroidAdb.deviceSerials().count
                let tetherUp = AndroidTether.isLikelyPresent()
                let hint = AndroidUsbCable.failureHint(tetherPresent: tetherUp, adbDevices: adbN)
                Log.info("Android USB: no transport — \(hint)")
                let name = label(for: target)
                let failed = MacSender(
                    transport: .tcp(.hostPort(host: "127.0.0.1",
                                              port: NWEndpoint.Port(rawValue: portNum)!)),
                    name: name, mode: mode, quality: quality,
                    audioOutput: audioOutput,
                    displaySerial: Self.displaySerial(for: id),
                    awaitingWake: awaitingWake)
                let session = DeviceSession(id: id, target: target, name: name, sender: failed)
                // Prefix so the row renders red — this is not a live stream.
                session.status = "Failed: \(hint)"
                sessions.append(session)
                return
            }
        }

        let name = label(for: target)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: quality, audioOutput: audioOutput,
                               displaySerial: Self.displaySerial(for: id),
                               awaitingWake: awaitingWake)
        let session = DeviceSession(id: id, target: target, name: name, sender: sender)
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak session] text in
            guard let session else { return }
            if session.status != text {
                session.status = text
            }
            Log.info("status[\(id)]: \(text)")
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session else { return }
            session.deviceID = info.id
            session.deviceKind = info.device
            if case .usb(let udid?) = session.target, let installID = info.id {
                self.installIDByUDID[udid] = installID
            }
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
        }
        sender.onStats = { [weak session] frames, mbps in
            // Throttle UI: sub-Mbps flicker was redrawing SessionRow every second.
            guard let session else { return }
            session.framesSent = frames
            if abs(session.mbps - mbps) >= 0.15 {
                session.mbps = mbps
            }
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator).
            // Android USB auto-reconnects via autoConnect() when the cable
            // is still present (unless the user hit Disconnect).
            guard let self, let session else { return }
            let wasAndroid = if case .androidUsb = session.target { true } else { false }
            Log.info("device disconnected — session \(session.id) stopped")
            self.end(session)
            if wasAndroid {
                // Brief pause so the receiver can re-bind :9000, then re-dial.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.autoConnect()
                }
            }
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session else { return }
            let target = session.target
            Log.info("session \(session.id) asleep — display down, waiting for wake")
            self.end(session)
            self.connect(to: target, awaitingWake: true)
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            self.end(session)
        }
        sessions.append(session)
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
            }
        }
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .wifi: wifiRemembered.remove(session.id)
        case .androidUsb: usbDisabled.insert(session.id)
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if session.onUSB, let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { wifiRemembered.remove("wifi:\(name)") }
        end(session)
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    private func end(_ session: DeviceSession) {
        session.sender.stop()
        sessions.removeAll { $0.id == session.id }
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let targets = sessions.map(\.target)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        // Ensure speakers are restored before a Mac-audio session starts.
        if audioOutput == .mac {
            SystemAudioMute.forceReleaseAll()
        }
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    private var restartWorkItem: DispatchWorkItem?

    /// Debounced restart so menu picks feel instant: the menu closes right
    /// away; the (slow) stream rebuild runs ~0.35s later and coalesces rapid
    /// option flips into a single reconnect.
    func scheduleRestartAll() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restartAll()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?
        let androidUsbTarget: ConnectionTarget?

        var transportLabel: String {
            if androidUsbTarget != nil { return "USB (Android)" }
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }
        /// Lowest latency first. Network/Wi‑Fi is the default path; USB only
        /// when the user (or cable auto-connect for Apple) picks it.
        var preferredTarget: ConnectionTarget? {
            androidUsbTarget ?? usbTarget ?? wifiTarget
        }

        init(id: String, name: String,
             usbTarget: ConnectionTarget? = nil,
             wifiTarget: ConnectionTarget? = nil,
             androidUsbTarget: ConnectionTarget? = nil) {
            self.id = id
            self.name = name
            self.usbTarget = usbTarget
            self.wifiTarget = wifiTarget
            self.androidUsbTarget = androidUsbTarget
        }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        // Always list Android USB so a cabled/tethered tablet is never hidden
        // behind a failed poll. Label reflects live adb/tether/cable state;
        // Connect still explains what's missing if transport is not ready.
        // Not auto-connected: Network remains the default; user taps Connect.
        do {
            let target = ConnectionTarget.androidUsb
            coveredSessionIDs.insert(target.sessionID)
            let name = androidUsbAvailable
                ? androidUsbLabel
                : "Android USB (plug in · enable tether or USB debugging)"
            entries.append(DeviceEntry(
                id: target.sessionID,
                name: name,
                androidUsbTarget: target))
        }

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin, let name = serviceName(of: twin) { mergedServices.insert(name) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? "iPhone / iPad",
                usbTarget: usbTarget,
                wifiTarget: twin.map { .wifi($0) }))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for result in discovered {
            guard let name = serviceName(of: result), !mergedServices.contains(name)
            else { continue }
            let target = ConnectionTarget.wifi(result)
            coveredSessionIDs.insert(target.sessionID)
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(id: "service:\(name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.androidUsbTarget {
            if let s = session(for: target.sessionID) { return s }
        }
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Fire the system permission dialog on demand. macOS only shows each
    /// dialog once per reset — after that the call just (re)registers the
    /// app in System Settings, so the row exists to toggle manually.
    ///
    /// Always also open the Privacy pane: on recent macOS (and for ad-hoc /
    /// freshly rebuilt binaries) the dialog is easy to miss or never appears,
    /// and the only reliable grant path is the Screen Recording list toggle.
    func requestScreenRecording() {
        // Register the app with TCC first so a row exists to toggle.
        CGRequestScreenCaptureAccess()
        Self.openPrivacyPane("Privacy_ScreenCapture")
        // Preflight can lag a beat after the user flips the switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refresh() }
    }

    func requestAccessibility() {
        _ = InputInjector.ensureAccessibilityPermission()
        Self.openPrivacyPane("Privacy_Accessibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refresh() }
    }

    /// Open System Settings → Privacy for the given anchor.
    /// Tries Sequoia/Tahoe URLs first, then the legacy preference pane.
    static func openPrivacyPane(_ anchor: String) {
        // macOS 15+ Settings deep links (extension id form).
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    // Optional so the view still compiles/previews without an updater (e.g.
    // if Sparkle ever fails to start); the button just disables itself then.
    let updater: SPUStandardUpdaterController?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay (Android)")
                        .font(.title3.bold())
                    Text("Your iPads and iPhones as extra displays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.running {
                    Button(role: .destructive) {
                        controller.disconnectAll()
                    } label: {
                        Label("Disconnect All", systemImage: "xmark.circle.fill")
                    }
                    .controlSize(.large)
                    .help("End every session and free the virtual displays")
                }
            }
            .padding(16)

            // Screen Recording is required for any stream. Without it USB/Wi‑Fi
            // can show "Connected" while the tablet stays black (fps=0) — surface
            // that before the device list so it is not mistaken for a cable fault.
            if !permissions.screenRecording {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Recording required")
                            .font(.headline)
                        Text("USB and Wi‑Fi both need this. Enable “OpenDisplay Dev” (or OpenDisplay) under System Settings → Privacy & Security → Screen Recording, then quit and reopen this app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Screen Recording Settings…") {
                            permissions.requestScreenRecording()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            Divider()

            // Settings
            ScrollView {
            Form {
                Section("Devices") {
                    if controller.deviceEntries.isEmpty {
                        Text("No devices found — same Wi‑Fi + OpenDisplay on the tablet, or USB: enable USB debugging (adb) or USB tethering (Mac needs a tether IP; charge-only / accessory mode will not work).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.deviceEntries) { entry in
                        if let session = controller.session(for: entry) {
                            // Title from the entry, not the session: the
                            // session name was snapshotted at connect time,
                            // often before lockdown resolved the real name.
                            SessionRow(title: entry.name, session: session,
                                       controller: controller)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Circle()
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.transportLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let target = entry.preferredTarget {
                                    Button {
                                        controller.connect(to: target, userInitiated: true)
                                    } label: {
                                        Label("Connect", systemImage: "link")
                                    }
                                    .controlSize(.regular)
                                    .buttonStyle(.borderedProminent)
                                    .help("Start streaming to this device")
                                }
                            }
                        }
                    }
                }

                // Use buttons (not segmented pickers): more reliable click targets
                // in NSHostingView while a stream is running.
                LabeledContent("Mode") {
                    HStack(spacing: 8) {
                        settingButton("Extend", selected: controller.mode == .extend) {
                            guard controller.mode != .extend else { return }
                            controller.mode = .extend
                            controller.scheduleRestartAll()
                        }
                        settingButton("Mirror", selected: controller.mode == .mirror) {
                            guard controller.mode != .mirror else { return }
                            controller.mode = .mirror
                            controller.scheduleRestartAll()
                        }
                    }
                }

                if controller.mode == .extend {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Screen position") {
                            HStack(spacing: 8) {
                                ForEach(DisplaySide.allCases, id: \.self) { side in
                                    settingButton(side.shortLabel, selected: controller.displaySide == side) {
                                        guard controller.displaySide != side else { return }
                                        controller.displaySide = side
                                        controller.scheduleRestartAll()
                                    }
                                }
                            }
                        }
                        Text(controller.displaySide == .left
                             ? "Tablet sits left of the Mac — move the mouse left to reach it."
                             : "Tablet sits right of the Mac — move the mouse right to reach it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle(isOn: $controller.focusRetrieveEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Click to restore to Mac")
                                Text(controller.focusRetrieveEnabled
                                     ? "Dock, Cmd+Tab, or clicking an app pulls its windows off the tablet onto this Mac."
                                     : "Off by default — windows stay on the tablet until you press Retrieve / Send.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                        .help("When enabled, activating an app from the Mac moves that app’s windows from the tablet back here. Off by default. Needs Accessibility.")
                        if controller.sessions.contains(where: { $0.sender.canHostWindows }) {
                            Button {
                                let n = controller.retrieveAllWindowsToMac()
                                _ = n
                            } label: {
                                Label("Retrieve Windows to Mac", systemImage: "rectangle.portrait.and.arrow.left")
                            }
                            .controlSize(.small)
                            .help("Move every window currently on the tablet (or stuck off-screen) back onto your Mac. Needs Accessibility permission.")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Quality") {
                        HStack(spacing: 8) {
                            ForEach(StreamQuality.allCases, id: \.self) { q in
                                settingButton(shortQuality(q), selected: controller.quality == q) {
                                    guard controller.quality != q else { return }
                                    controller.quality = q
                                    controller.scheduleRestartAll()
                                }
                            }
                        }
                    }
                    Text(controller.quality.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Play audio on") {
                        HStack(spacing: 8) {
                            ForEach(AudioOutput.allCases, id: \.self) { out in
                                settingButton(out.label, selected: controller.audioOutput == out) {
                                    guard controller.audioOutput != out else { return }
                                    controller.audioOutput = out
                                    controller.scheduleRestartAll()
                                }
                            }
                        }
                    }
                    Text(controller.audioOutput.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Show app in") {
                        HStack(spacing: 8) {
                            ForEach(AppPresentation.allCases, id: \.self) { p in
                                settingButton(p.label, selected: controller.presentation == p) {
                                    controller.presentation = p
                                }
                            }
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays for free-form arrangement. The Screen position control above re-applies Left/Right on the next connect.")

                Section("Permissions") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture",
                        request: { permissions.requestScreenRecording() }
                    )
                    permissionRow(
                        "Accessibility",
                        granted: permissions.accessibility,
                        help: "Required for touch input from the device.",
                        anchor: "Privacy_Accessibility",
                        request: { permissions.requestAccessibility() }
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Devices list, allow OpenDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the OpenDisplay app open there.",
                        anchor: "Privacy_LocalNetwork"
                    )
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Fixed panel height for MenuBarExtra; form scrolls when content is tall.

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.running ? .green : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(controller.running
                     ? "\(controller.sessions.count) device\(controller.sessions.count == 1 ? "" : "s") connected"
                     : "Idle")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // Local 0.0.0 builds must not offer Sparkle “update” to upstream.
                if let updater,
                   (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) != "0.0.0" {
                    CheckForUpdatesView(updater: updater)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440, height: 560)
        // Injection pause is owned by StatusItemController (panel open/close).
        // Do NOT toggle it from onAppear/onDisappear — SwiftUI rebuilds this
        // view on status ticks and would re-enable tablet input mid-click.
    }

    private func shortQuality(_ q: StreamQuality) -> String {
        switch q {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        }
    }

    @ViewBuilder
    private func settingButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        // Selected = filled blue (prominent); unselected = outline.
        if selected {
            Button(action: action) {
                Text(title)
                    .fontWeight(.semibold)
                    .frame(minWidth: 64)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        } else {
            Button(action: action) {
                Text(title)
                    .frame(minWidth: 64)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Requests permission and opens System Settings. Look for \"OpenDisplay Dev\" (debug) or \"OpenDisplay\" (release) under \(title) and enable the toggle. You may need to quit and reopen the app after enabling.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}

/// "Check for Updates…" button wired to Sparkle. Follows Sparkle 2's
/// documented SwiftUI pattern: a small view model publishes the updater's
/// `canCheckForUpdates` so the button disables itself while a check is
/// already running (or the updater isn't ready).
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater.updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater.updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .controlSize(.small)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text("\(session.transportLabel) · \(session.status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if session.mbps > 0 {
                    Text("\(String(format: "%.1f", session.mbps)) Mbit/s")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Short labels that fit the panel width (no “Send W…” / “Discon…” truncation).
            // Full wording is in tooltips.
            HStack(spacing: 6) {
                if session.sender.canHostWindows {
                    sessionChip(
                        "Send",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        help: "Move the frontmost app’s window onto this tablet. Focus that app first, then press Send. Needs Accessibility."
                    ) {
                        _ = session.sender.moveFrontWindowToDisplay()
                    }
                    sessionChip(
                        "Retrieve",
                        systemImage: "rectangle.portrait.and.arrow.left",
                        help: "Move windows from this tablet back onto the Mac. Needs Accessibility."
                    ) {
                        _ = session.sender.retrieveWindowsToMac()
                    }
                }
                sessionChip(
                    "Retry",
                    systemImage: "arrow.clockwise",
                    help: "Drop the TCP link and reconnect (keeps the virtual display when possible)."
                ) {
                    session.sender.forceReconnect()
                }

                Spacer(minLength: 4)

                Button(role: .destructive) {
                    controller.disconnect(session)
                } label: {
                    Text("Stop")
                        .frame(minWidth: 44)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
                .help("Stop streaming to this device and free its virtual display")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sessionChip(_ title: String, systemImage: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }
}
