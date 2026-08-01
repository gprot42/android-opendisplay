import Foundation

/// Appends timestamped lines to /tmp/opensidecar-mac.log (and stdout) so the
/// stream can be debugged without a debugger attached.
enum Log {
    private static let path = "/tmp/opensidecar-mac.log"
    private static let queue = DispatchQueue(label: "log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        fputs(line, stdout)
        fflush(stdout)
        queue.async {
            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: data)
                return
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
