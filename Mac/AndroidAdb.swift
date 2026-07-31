import Foundation

/// Android USB path: reverse TCP via the platform `adb` tool, then the Mac
/// dials loopback. Network/Wi‑Fi remains the default discovery path; this is
/// only used when the user picks **Android USB**.
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

    /// `adb [-s serial] reverse tcp:PORT tcp:PORT` so Mac → 127.0.0.1:PORT reaches the phone.
    @discardableResult
    static func reverse(port: UInt16, serial: String? = nil) -> Bool {
        guard let adb = adbPath else {
            Log.info("adb not found — install platform-tools for Android USB")
            return false
        }
        let serials = deviceSerials()
        guard !serials.isEmpty else {
            Log.info("adb: no device in 'device' state")
            return false
        }
        let target = serial.flatMap { serials.contains($0) ? $0 : nil } ?? serials[0]
        // Remove any stale reverse, then set fresh.
        _ = shell("\(adb) -s \(target) reverse --remove tcp:\(port)")
        let out = shell("\(adb) -s \(target) reverse tcp:\(port) tcp:\(port)")
        let ok = !out.lowercased().contains("error") && !out.lowercased().contains("failed")
        Log.info("adb reverse tcp:\(port) on \(target): \(ok ? "ok" : out)")
        return ok
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
