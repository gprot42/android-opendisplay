import Foundation

/// Detect an Android handset/tablet on the USB bus (even when neither
/// tethering nor adb has produced a usable transport yet).
///
/// Used so the Mac UI can show **Android USB** while the cable is in, and
/// give a precise “what’s wrong” status instead of “No devices found”.
enum AndroidUsbCable {

    struct Device: Equatable {
        let name: String
        let vendorId: Int
        let productId: Int
        let serial: String?

        /// Google composite function ids (common Pixel / AOSP).
        /// See `android/system/core/rootdir/ueventd.rc` / gadget configs.
        var likelyRndis: Bool {
            // 0x4EE8 RNDIS, 0x4EE9 RNDIS+ADB, plus a few OEM neighbours
            [0x4EE8, 0x4EE9, 0x4EEA /* sometimes NCM */, 0x4EEC].contains(productId)
                || productId == 0x2D00 /* older RNDIS */
                || productId == 0x2D01
        }

        var likelyAdb: Bool {
            // ADB is usually OR’d into the product id’s low function set.
            // Common Google: 0x4EE1 accessory (no adb), 0x4EE2 acc+adb,
            // 0x4EEB MTP+adb, 0x4EE9 RNDIS+adb, …
            let adbish: Set<Int> = [
                0x4EE2, 0x4EE5, 0x4EE7, 0x4EE9, 0x4EEB, 0x4EED, 0x4EEF,
                0xD00D, // bootloader sometimes
            ]
            if adbish.contains(productId) { return true }
            // Many OEMs expose adb with product names only; leave false.
            return false
        }

        var shortModeHint: String {
            if likelyRndis { return "USB network (tether)" }
            if likelyAdb { return "USB debugging" }
            switch productId {
            case 0x4EE1: return "accessory/charging (not tether, not adb)"
            case 0x4EE6, 0x4EEA: return "file transfer (enable tethering or debugging)"
            case 0x4EE4: return "MIDI"
            default: return String(format: "USB mode 0x%04X", productId)
            }
        }
    }

    /// Cache ioreg results — full USB tree dumps are expensive and the poll
    /// loop was spawning one every 2s on a utility queue (UI hitch when
    /// contended).
    private static let cacheLock = NSLock()
    private static var cachedDevices: [Device] = []
    private static var cacheAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 3

    /// Android-ish devices currently on the USB tree.
    static func connected() -> [Device] {
        cacheLock.lock()
        if Date().timeIntervalSince(cacheAt) < cacheTTL {
            let hit = cachedDevices
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let out = shell("ioreg -p IOUSB -w0 -l")
        let parsed = parseIoreg(out)

        cacheLock.lock()
        cachedDevices = parsed
        cacheAt = Date()
        cacheLock.unlock()
        return parsed
    }

    static func primary() -> Device? {
        let all = connected()
        // Prefer something that already looks like tether/adb, else first.
        return all.first(where: { $0.likelyRndis || $0.likelyAdb }) ?? all.first
    }

    /// True when a cable is present (name for the picker).
    static func displayName() -> String? {
        guard let d = primary() else { return nil }
        return "\(d.name) (USB)"
    }

    /// Why Android USB cannot dial yet (for session status).
    static func failureHint(tetherPresent: Bool, adbDevices: Int) -> String {
        if adbDevices > 0 {
            return "adb device seen but forward failed — check platform-tools"
        }
        if tetherPresent {
            return "USB tether up, but nothing on :9000 — open OpenDisplay on the tablet, select USB, leave the app open (Waiting for Mac…)"
        }
        if let d = primary() {
            if d.likelyRndis {
                return "\(d.name): USB network mode, but Mac has no tether IP yet — wait a few seconds or toggle USB tethering"
            }
            return "\(d.name) plugged in · \(d.shortModeHint). On tablet: enable USB tethering, or USB debugging for adb (keeps Mac Wi‑Fi)."
        }
        // Stale Network service name without a live interface.
        if networksetupMentionsAndroid() {
            return "Mac has a “phone” network service but no live USB interface — toggle USB tethering off/on on the tablet"
        }
        return "No Android USB. Cable (data), then USB tethering or USB debugging + adb."
    }

    // MARK: - Parse

    /// Known Android / phone vendor IDs (USB-IF).
    private static let vendorIds: Set<Int> = [
        0x18D1, // Google
        0x04E8, // Samsung
        0x22B8, // Motorola
        0x0BB4, // HTC
        0x12D1, // Huawei
        0x2717, // Xiaomi
        0x2A70, // OnePlus (some)
        0x05C6, // Qualcomm (many OEMs)
        0x0FCE, // Sony
        0x2080, // Barnes & Noble / Nook (rare)
        0x2B4C, // ZTE
        0x0E8D, // MediaTek
    ]

    private static func parseIoreg(_ text: String) -> [Device] {
        // Split into device blocks starting at "+-o …@…".
        var devices: [Device] = []
        var currentName: String?
        var vendor: Int?
        var product: Int?
        var serial: String?

        func flush() {
            guard let v = vendor, vendorIds.contains(v), let p = product else {
                currentName = nil; vendor = nil; product = nil; serial = nil
                return
            }
            let name = (currentName?.isEmpty == false ? currentName! : "Android")
            // Skip pure hubs / Apple devices if a vendor slipped through.
            if name.localizedCaseInsensitiveContains("hub") {
                currentName = nil; vendor = nil; product = nil; serial = nil
                return
            }
            devices.append(Device(name: name, vendorId: v, productId: p, serial: serial))
            currentName = nil; vendor = nil; product = nil; serial = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.contains("+-o ") && line.contains("@") {
                flush()
                // "+-o Pixel Tablet@01100000  <class …>"
                if let range = line.range(of: #"[+][-]o\s+([^@]+)@"#, options: .regularExpression) {
                    var n = String(line[range])
                    n = n.replacingOccurrences(of: "+-o", with: "")
                    n = n.replacingOccurrences(of: "@", with: "")
                    currentName = n.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if let v = intValue(in: line, key: "idVendor") { vendor = v }
            if let p = intValue(in: line, key: "idProduct") { product = p }
            if let s = stringValue(in: line, key: "USB Product Name"), !s.isEmpty {
                currentName = s
            }
            if let s = stringValue(in: line, key: "USB Serial Number"), !s.isEmpty {
                serial = s
            }
        }
        flush()

        // De-dupe by serial/name.
        var seen = Set<String>()
        return devices.filter { d in
            let k = d.serial ?? "\(d.vendorId):\(d.productId):\(d.name)"
            return seen.insert(k).inserted
        }
    }

    private static func intValue(in line: String, key: String) -> Int? {
        // "idVendor" = 6353
        guard line.contains("\"\(key)\"") else { return nil }
        guard let eq = line.range(of: "=") else { return nil }
        let rhs = line[eq.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(rhs)
    }

    private static func stringValue(in line: String, key: String) -> String? {
        // "USB Product Name" = "Pixel Tablet"
        guard line.contains("\"\(key)\"") else { return nil }
        guard let first = line.range(of: "\""),
              let r = line.range(of: "\"", range: first.upperBound..<line.endIndex) else { return nil }
        // Find the value in quotes after =
        guard let eq = line.range(of: "=") else { return nil }
        let after = line[eq.upperBound...]
        guard let q1 = after.range(of: "\"") else { return nil }
        let rest = after[q1.upperBound...]
        guard let q2 = rest.range(of: "\"") else { return nil }
        return String(rest[..<q2.lowerBound])
    }

    private static func networksetupMentionsAndroid() -> Bool {
        let out = shell("/usr/sbin/networksetup -listallnetworkservices")
        let keys = ["pixel", "android", "samsung", "phone", "rndis", "usb"]
        return out.lowercased().split(separator: "\n").contains { line in
            let l = line.lowercased()
            // Ignore the legend line.
            if l.contains("asterisk") { return false }
            return keys.contains { l.contains($0) }
        }
    }

    @discardableResult
    private static func shell(_ command: String) -> String {
        // Non-login shell + timeout (see AndroidAdb.shell).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return ""
        }
        let deadline = Date().addingTimeInterval(1.5)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning { task.terminate(); return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
