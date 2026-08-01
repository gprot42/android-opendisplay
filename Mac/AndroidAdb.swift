import Foundation

/// Android USB path: TCP forward via the platform `adb` tool, then the Mac
/// dials loopback. Network/Wi‑Fi remains the default discovery path; this is
/// only used when the user picks **Android USB**.
///
/// Direction matters: the phone **listens** on :9000 and the Mac **connects**.
/// That is `adb forward` (host → device), not `adb reverse` (device → host).
/// Reverse fails while the app is listening because the device port is already
/// bound — the classic “USB not working” symptom on Pixel / Android 16.
enum AndroidAdb {
    /// Cached path to adb, or empty if not found.
    private static let adbPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "\(NSHomeDirectory())/Android/Sdk/platform-tools/adb",
            "/usr/bin/adb",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Fall back to PATH.
        if let fromPath = shell("/usr/bin/which adb")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first
            .map(String.init),
           !fromPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: fromPath) {
            return fromPath
        }
        return nil
    }()

    static var isAvailable: Bool { adbPath != nil }

    /// Serials of devices currently listed by `adb devices` (state = device).
    static func deviceSerials() -> [String] {
        guard let adb = adbPath else { return [] }
        let out = shell("\(adb) devices")
        var serials: [String] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, parts[1] == "device" else { continue }
            let serial = String(parts[0])
            if serial != "List" { serials.append(serial) }
        }
        return serials
    }

    /// Human label for the device list, or nil when no Android is plugged in.
    static func displayName() -> String? {
        let serials = deviceSerials()
        guard !serials.isEmpty else { return nil }
        if serials.count == 1 {
            let model = prop(serial: serials[0], key: "ro.product.model")
            if let model, !model.isEmpty { return "\(model) (USB)" }
            return "Android USB"
        }
        return "Android USB (\(serials.count) devices)"
    }

    /// Host port already forwarded to `devicePort` on `serial`, if any.
    static func existingHostPort(devicePort: UInt16, serial: String) -> UInt16? {
        guard let adb = adbPath else { return nil }
        // Global list is reliable across adb versions; filter by serial.
        let out = shell("\(adb) forward --list")
        // Lines: "SERIAL tcp:HOST tcp:DEVICE"
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3, String(parts[0]) == serial,
                  let host = parseTcpPort(parts[1]),
                  let device = parseTcpPort(parts[2]),
                  device == devicePort else { continue }
            return host
        }
        return nil
    }

    /// Ensure a host→device forward exists without tearing down a working
    /// tunnel (remove + re-add drops live TCP sessions). Returns the host
    /// port to dial on loopback, or `nil` if setup failed.
    @discardableResult
    static func ensureForward(devicePort: UInt16, serial: String? = nil) -> UInt16? {
        guard let adb = adbPath else {
            Log.info("adb not found — install platform-tools for Android USB")
            return nil
        }
        let serials = deviceSerials()
        guard !serials.isEmpty else {
            Log.info("adb: no device in 'device' state")
            return nil
        }
        let target = serial.flatMap { serials.contains($0) ? $0 : nil } ?? serials[0]
        if let existing = existingHostPort(devicePort: devicePort, serial: target) {
            return existing
        }
        return installForward(adb: adb, target: target, devicePort: devicePort)
    }

    /// Force a fresh forward (e.g. first connect). Prefer ``ensureForward``
    /// for live sessions so we don't RST an open stream every few seconds.
    @discardableResult
    static func forward(devicePort: UInt16, serial: String? = nil) -> UInt16? {
        guard let adb = adbPath else {
            Log.info("adb not found — install platform-tools for Android USB")
            return nil
        }
        let serials = deviceSerials()
        guard !serials.isEmpty else {
            Log.info("adb: no device in 'device' state")
            return nil
        }
        let target = serial.flatMap { serials.contains($0) ? $0 : nil } ?? serials[0]
        return installForward(adb: adb, target: target, devicePort: devicePort)
    }

    private static func installForward(adb: String, target: String, devicePort: UInt16) -> UInt16? {
        // Prefer matching ports; fall back when something else owns the host
        // listen socket (another tool, leftover forward, etc.).
        let hostCandidates: [UInt16] = [devicePort, 19_000, 19_001, 29_000]
        for hostPort in hostCandidates {
            // Only remove this host port if we're about to claim it — and only
            // when it isn't already the correct mapping.
            if let existing = existingHostPort(devicePort: devicePort, serial: target),
               existing == hostPort {
                Log.info("adb forward tcp:\(hostPort) → device tcp:\(devicePort) on \(target): already set")
                return hostPort
            }
            _ = shell("\(adb) -s \(target) forward --remove tcp:\(hostPort)")
            let out = shell("\(adb) -s \(target) forward tcp:\(hostPort) tcp:\(devicePort)")
            let lower = out.lowercased()
            let ok = !lower.contains("error") && !lower.contains("failed")
                && !lower.contains("cannot bind")
            if ok {
                Log.info("adb forward tcp:\(hostPort) → device tcp:\(devicePort) on \(target): ok")
                return hostPort
            }
            Log.info("adb forward tcp:\(hostPort) on \(target) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return nil
    }

    private static func parseTcpPort(_ token: Substring) -> UInt16? {
        // "tcp:9000"
        let s = String(token)
        guard s.hasPrefix("tcp:") else { return nil }
        return UInt16(s.dropFirst(4))
    }

    /// Legacy name — prefer ``ensureForward`` / ``forward``.
    @discardableResult
    @available(*, deprecated, renamed: "forward(devicePort:serial:)")
    static func reverse(port: UInt16, serial: String? = nil) -> Bool {
        forward(devicePort: port, serial: serial) != nil
    }

    private static func prop(serial: String, key: String) -> String? {
        guard let adb = adbPath else { return nil }
        let v = shell("\(adb) -s \(serial) shell getprop \(key)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    @discardableResult
    private static func shell(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "error: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
