import Foundation
import Network
import Darwin

/// Resolves a Bonjour OpenDisplay service to IPv4 + port for UI and Connect.
enum BonjourResolve {
    struct Address: Equatable {
        let host: String
        let port: UInt16
    }

    static func resolve(result: NWBrowser.Result, timeout: TimeInterval = 3.0) async -> Address? {
        guard case .service(let name, let type, let domain, _) = result.endpoint else {
            return nil
        }
        return await resolve(name: name, type: type, domain: domain, timeout: timeout)
    }

    static func resolve(
        name: String,
        type: String = "_opensidecar._tcp",
        domain: String = "local",
        timeout: TimeInterval = 3.0
    ) async -> Address? {
        // dns-sd is the most reliable resolver on macOS (NetService often fails
        // for third-party types without a scheduled run loop + peer options).
        if let viaDnsSd = await resolveViaDnsSd(name: name, type: type, domain: domain,
                                                 timeout: timeout) {
            return viaDnsSd
        }
        return await resolveViaNetService(name: name, type: type, domain: domain,
                                          timeout: timeout)
    }

    // MARK: - dns-sd CLI

    private static func resolveViaDnsSd(
        name: String, type: String, domain: String, timeout: TimeInterval
    ) async -> Address? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: dnsSdLookup(name: name, type: type,
                                                   domain: domain, timeout: timeout))
            }
        }
    }

    private static func dnsSdLookup(
        name: String, type: String, domain: String, timeout: TimeInterval
    ) -> Address? {
        // Normalize: dns-sd wants type without a trailing dot, domain without.
        var t = type
        while t.hasSuffix(".") { t = String(t.dropLast()) }
        if t.isEmpty { t = "_opensidecar._tcp" }
        var d = domain
        while d.hasSuffix(".") { d = String(d.dropLast()) }
        if d.isEmpty { d = "local" }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        // -t N: exit after N seconds; -L: lookup service instance.
        task.arguments = ["-t", String(max(1, Int(timeout.rounded()))), "-L", name, t, d]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            Log.info("dns-sd launch failed: \(error)")
            return nil
        }
        // Wait up to timeout+1s
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            task.waitUntilExit()
            group.leave()
        }
        _ = group.wait(timeout: .now() + timeout + 1.5)
        if task.isRunning { task.terminate() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        // Example:
        //   Pixel\032Tablet._opensidecar._tcp.local. can be reached at Android_xxx.local.:9000
        guard let hostPort = parseDnsSdReachedAt(text) else { return nil }
        let port = hostPort.port
        // Prefer numeric IPv4 for the UI / dial.
        if let ip = ipv4(forHost: hostPort.host) {
            return Address(host: ip, port: port)
        }
        return Address(host: hostPort.host, port: port)
    }

    private static func parseDnsSdReachedAt(_ text: String) -> (host: String, port: UInt16)? {
        // "can be reached at HOST:PORT" — HOST may end with a trailing dot.
        guard let re = try? NSRegularExpression(
            pattern: #"can be reached at\s+(\S+):(\d+)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range),
              let hostR = Range(match.range(at: 1), in: text),
              let portR = Range(match.range(at: 2), in: text),
              let port = UInt16(text[portR])
        else { return nil }
        var host = String(text[hostR])
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        // Unescape dns-sd \032 → space in hostnames is rare; leave as-is for hosts.
        return (host, port == 0 ? 9000 : port)
    }

    private static func ipv4(forHost host: String) -> String? {
        // Already an IPv4 literal?
        if host.split(separator: ".").count == 4,
           host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return host
        }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let p = ptr {
            if p.pointee.ai_family == AF_INET, let sa = p.pointee.ai_addr {
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if !ip.isEmpty && ip != "0.0.0.0" { return ip }
            }
            ptr = p.pointee.ai_next
        }
        return nil
    }

    // MARK: - NetService fallback

    private static func resolveViaNetService(
        name: String, type: String, domain: String, timeout: TimeInterval
    ) async -> Address? {
        await withCheckedContinuation { cont in
            var t = type
            if !t.hasSuffix(".") { t += "." }
            var d = domain.isEmpty ? "local." : domain
            if !d.hasSuffix(".") { d += "." }
            let box = NetServiceBox(name: name, type: t, domain: d, timeout: timeout) { addr in
                cont.resume(returning: addr)
            }
            NetServiceBox.retain(box)
            box.start()
        }
    }

    private final class NetServiceBox: NSObject, NetServiceDelegate {
        private static var inflight = [NetServiceBox]()
        private static let lock = NSLock()

        static func retain(_ box: NetServiceBox) {
            lock.lock(); inflight.append(box); lock.unlock()
        }
        private static func release(_ box: NetServiceBox) {
            lock.lock(); inflight.removeAll { $0 === box }; lock.unlock()
        }

        private let service: NetService
        private let timeout: TimeInterval
        private var finished = false
        private let onDone: (Address?) -> Void
        private var timer: Timer?

        init(name: String, type: String, domain: String, timeout: TimeInterval,
             onDone: @escaping (Address?) -> Void) {
            self.service = NetService(domain: domain, type: type, name: name)
            self.timeout = timeout
            self.onDone = onDone
            super.init()
            self.service.delegate = self
        }

        func start() {
            let work = { [self] in
                self.service.schedule(in: .current, forMode: .common)
                self.service.resolve(withTimeout: self.timeout)
                self.timer = Timer.scheduledTimer(withTimeInterval: self.timeout + 0.4,
                                                  repeats: false) { [weak self] _ in
                    self?.finish(nil)
                }
                RunLoop.current.add(self.timer!, forMode: .common)
            }
            if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let port = UInt16(clamping: max(0, sender.port))
            guard port > 0 else { finish(nil); return }
            for data in sender.addresses ?? [] {
                var found: String?
                data.withUnsafeBytes { raw in
                    guard raw.count >= MemoryLayout<sockaddr>.size,
                          let base = raw.bindMemory(to: sockaddr.self).baseAddress else { return }
                    guard base.pointee.sa_family == sa_family_t(AF_INET) else { return }
                    var addr = UnsafeRawPointer(base)
                        .assumingMemoryBound(to: sockaddr_in.self).pointee
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    if !ip.isEmpty && ip != "0.0.0.0" && !ip.hasPrefix("169.254.") {
                        found = ip
                    }
                }
                if let ip = found {
                    finish(Address(host: ip, port: port))
                    return
                }
            }
            if let hostName = sender.hostName, !hostName.isEmpty {
                var host = hostName
                if host.hasSuffix(".") { host = String(host.dropLast()) }
                if let ip = BonjourResolve.ipv4(forHost: host) {
                    finish(Address(host: ip, port: port))
                } else {
                    finish(Address(host: host, port: port))
                }
                return
            }
            finish(nil)
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
            finish(nil)
        }

        private func finish(_ addr: Address?) {
            guard !finished else { return }
            finished = true
            timer?.invalidate(); timer = nil
            service.stop(); service.delegate = nil
            onDone(addr)
            Self.release(self)
        }
    }
}
