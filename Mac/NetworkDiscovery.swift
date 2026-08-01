import Foundation
import Network
import Darwin

/// Discovers **verified** OpenDisplay receivers via multicast signature probe.
///
/// Unicast UDP/TCP to tablets is often blocked by AP client isolation; multicast
/// (same class of traffic as mDNS) still gets through. Android answers with
/// `sig=OpenDisplay` — we never list plain ARP neighbors.
enum NetworkDiscovery {
    struct Hit: Equatable, Identifiable {
        var id: String { "\(host):\(port):\(installId)" }
        let host: String
        let port: UInt16
        let name: String
        let installId: String
        let protocolVersion: Int
    }

    struct Result: Equatable {
        var hits: [Hit]
        var bases: [String]
    }

    static let mcastGroup = "239.255.90.0"
    static let mcastPort: UInt16 = 9010
    private static let signature = "OpenDisplay"
    private static let probeType = "od-probe"
    private static let ackType = "od-ack"

    /// Multicast probe (primary) + optional unicast to ARP neighbors (secondary).
    static func scanLAN(port: UInt16 = 9000, fullSweep: Bool = false) async -> Result {
        let bases = localIPv4Bases()
        Log.info("LAN scan: multicast \(mcastGroup):\(mcastPort) bases=\(bases.joined(separator: ","))")

        // 1) Multicast — finds all listening OpenDisplay apps on the LAN.
        var hits = await multicastProbe(timeoutMs: 600)

        // 2) Unicast fallback to ARP neighbors (works when isolation is off).
        if hits.isEmpty {
            let neighbors = arpNeighborIPs(inBases: Set(bases), completeOnly: true)
                .filter { !localIPv4Addresses().contains($0) }
            if !neighbors.isEmpty {
                Log.info("LAN scan: unicast probe \(neighbors.count) neighbor(s)")
                let uni = await unicastProbeMany(neighbors, port: mcastPort, timeoutMs: 300, maxConcurrent: 32)
                hits.append(contentsOf: uni)
            }
        }

        // 3) Rare: full unicast sweep of discovery port only (not TCP 9000).
        if hits.isEmpty && fullSweep {
            var ordered: [String] = []
            for base in bases {
                ordered += (100...200).map { "\(base).\($0)" }
                ordered += (1...99).map { "\(base).\($0)" }
                ordered += (201...254).map { "\(base).\($0)" }
            }
            let selfIPs = localIPv4Addresses()
            ordered = ordered.filter { !selfIPs.contains($0) }
            Log.info("LAN scan: full unicast \(ordered.count) on :\(mcastPort)")
            let uni = await unicastProbeMany(ordered, port: mcastPort, timeoutMs: 120, maxConcurrent: 96)
            hits.append(contentsOf: uni)
        }

        // Dedupe by host
        var byHost: [String: Hit] = [:]
        for h in hits { byHost[h.host] = h }
        let unique = byHost.values.sorted {
            $0.host.localizedStandardCompare($1.host) == .orderedAscending
        }
        Log.info("LAN scan: verified=\(unique.count)\(unique.isEmpty ? "" : " → \(unique.map { "\($0.name)@\($0.host)" }.joined(separator: ", "))")")
        return Result(hits: unique, bases: bases)
    }

    static func triggerLocalNetworkPermissionPrompt() {
        // Join multicast briefly so TCC grants Local Network.
        Task {
            _ = await multicastProbe(timeoutMs: 400)
        }
    }

    // MARK: - Multicast probe (main path)

    private static func multicastProbe(timeoutMs: Int) async -> [Hit] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: multicastProbeSync(timeoutMs: timeoutMs))
            }
        }
    }

    /// Nonce must fit in JSON integer without precision loss (≤ 2^53).
    private static func freshNonce() -> UInt64 {
        UInt64(UInt32.random(in: 1...UInt32.max))
    }

    private static func multicastProbeSync(timeoutMs: Int) -> [Hit] {
        let nonce = freshNonce()
        let req = #"{"t":"\#(probeType)","v":1,"n":\#(nonce)}"#
        guard let reqData = req.data(using: .utf8) else { return [] }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        // Bind :9010 so multicast acks to the group port are received; unicast
        // acks also land here because sendto uses this socket's source port.
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = mcastPort.bigEndian
        bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        _ = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Join group so multicast acks are received (Android may reply to group).
        let ifAddrs = localIPv4InterfaceAddresses()
        if ifAddrs.isEmpty {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr(mcastGroup)
            mreq.imr_interface.s_addr = INADDR_ANY.bigEndian
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        } else {
            for ifAddr in ifAddrs {
                var mreq = ip_mreq()
                mreq.imr_multiaddr.s_addr = inet_addr(mcastGroup)
                mreq.imr_interface.s_addr = ifAddr
                setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
            }
        }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = mcastPort.bigEndian
        dest.sin_addr.s_addr = inet_addr(mcastGroup)

        var ttl: UInt8 = 1 // LAN only
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))
        var loop: UInt8 = 0
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout.size(ofValue: loop)))

        // Send from each local interface so the packet leaves Wi‑Fi, not VPN.
        let sendOnce: (in_addr_t?) -> Void = { iface in
            if let iface {
                var ifa = iface
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifa, socklen_t(MemoryLayout.size(ofValue: ifa)))
            }
            _ = reqData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, base, reqData.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        if ifAddrs.isEmpty {
            sendOnce(nil)
        } else {
            for ifa in ifAddrs { sendOnce(ifa) }
        }
        usleep(40_000)
        if ifAddrs.isEmpty {
            sendOnce(nil)
        } else {
            for ifa in ifAddrs { sendOnce(ifa) }
        }

        var hits: [Hit] = []
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var tv = timeval(
                tv_sec: __darwin_time_t(remaining),
                tv_usec: suseconds_t((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000)
            )
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var buf = [UInt8](repeating: 0, count: 1024)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: Int = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
            let fromHost = String(cString: hostBuf)
            if localIPv4Addresses().contains(fromHost) { continue } // ignore our own multicast loop

            if let hit = parseAck(bytes: Array(buf[0..<n]), expectedNonce: nonce, fallbackHost: fromHost) {
                if !hits.contains(where: { $0.host == hit.host }) {
                    hits.append(hit)
                }
            }
        }
        return hits
    }

    // MARK: - Unicast fallback

    private static func unicastProbeMany(
        _ hosts: [String], port: UInt16, timeoutMs: Int32, maxConcurrent: Int
    ) async -> [Hit] {
        await withTaskGroup(of: Hit?.self, returning: [Hit].self) { group in
            var results: [Hit] = []
            var index = 0
            let seed = min(maxConcurrent, hosts.count)
            for _ in 0..<seed {
                let host = hosts[index]; index += 1
                group.addTask { unicastProbe(host: host, port: port, timeoutMs: timeoutMs) }
            }
            while let hit = await group.next() {
                if let h = hit { results.append(h) }
                if index < hosts.count {
                    let host = hosts[index]; index += 1
                    group.addTask { unicastProbe(host: host, port: port, timeoutMs: timeoutMs) }
                }
            }
            return results
        }
    }

    private static func unicastProbe(host: String, port: UInt16, timeoutMs: Int32) -> Hit? {
        let nonce = freshNonce()
        let req = #"{"t":"\#(probeType)","v":1,"n":\#(nonce)}"#
        guard let reqData = req.data(using: .utf8) else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: __darwin_time_t(timeoutMs / 1000),
                         tv_usec: suseconds_t((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return nil }

        let sent = reqData.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, reqData.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == reqData.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 512)
        let n = recvfrom(fd, &buf, buf.count, 0, nil, nil)
        guard n > 0 else { return nil }
        return parseAck(bytes: Array(buf[0..<n]), expectedNonce: nonce, fallbackHost: host)
    }

    private static func parseAck(bytes: [UInt8], expectedNonce: UInt64, fallbackHost: String) -> Hit? {
        guard let text = String(bytes: bytes, encoding: .utf8),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard (obj["t"] as? String) == ackType else { return nil }
        guard (obj["sig"] as? String) == signature else { return nil }
        let ackNonce: UInt64? = {
            if let u = obj["n"] as? UInt64 { return u }
            if let i = obj["n"] as? Int { return UInt64(i) }
            if let d = obj["n"] as? Double { return UInt64(d) }
            if let s = obj["n"] as? String { return UInt64(s) }
            return nil
        }()
        guard ackNonce == expectedNonce else { return nil }

        let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (obj["id"] as? String) ?? ""
        let pv = (obj["pv"] as? Int) ?? Int("\(obj["pv"] ?? 0)") ?? 0
        let replyPort = UInt16(truncatingIfNeeded: (obj["port"] as? Int)
            ?? Int("\(obj["port"] ?? 9000)") ?? 9000)

        return Hit(
            host: fallbackHost,
            port: replyPort == 0 ? 9000 : replyPort,
            name: (name?.isEmpty == false ? name! : "OpenDisplay"),
            installId: id,
            protocolVersion: pv
        )
    }

    // MARK: - System helpers

    /// IPv4 addresses of en* (Wi‑Fi/Ethernet) interfaces for multicast IF selection.
    private static func localIPv4InterfaceAddresses() -> [in_addr_t] {
        var out: [in_addr_t] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ifName = String(cString: p.pointee.ifa_name)
            guard ifName.hasPrefix("en") else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            out.append(sin.sin_addr.s_addr)
        }
        return out
    }

    static func arpNeighborIPs(inBases bases: Set<String>, completeOnly: Bool = true) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-an"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var ips: [String] = []
        let pattern = completeOnly
            ? #"\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]{11,})"#
            : #"\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        re.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            let ip = String(text[r])
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { return }
            let base = "\(parts[0]).\(parts[1]).\(parts[2])"
            guard bases.contains(base) else { return }
            ips.append(ip)
        }
        return Array(Set(ips)).sorted()
    }

    static func localIPv4Bases() -> [String] {
        var wifi: [String] = []
        var other: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ifName = String(cString: p.pointee.ifa_name)
            if ifName.hasPrefix("utun") || ifName.hasPrefix("ipsec") || ifName.hasPrefix("ppp") { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(addr, len, &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            if parts[0] == "169" && parts[1] == "254" { continue }
            if parts[0] == "100", let s = Int(parts[1]), (100...127).contains(s) { continue }
            let base = "\(parts[0]).\(parts[1]).\(parts[2])"
            if ifName.hasPrefix("en") { wifi.append(base) } else { other.append(base) }
        }
        var seen = Set<String>()
        var ordered: [String] = []
        for b in wifi + other where seen.insert(b).inserted { ordered.append(b) }
        return ordered
    }

    static func localIPv4Addresses() -> Set<String> {
        var addrs = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(addr, len, &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addrs.insert(String(cString: hostname))
        }
        return addrs
    }
}
