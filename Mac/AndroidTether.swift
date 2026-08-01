import Foundation
import Network
import Darwin

/// USB **without** USB debugging / adb.
///
/// When the tablet enables **USB tethering**, macOS gets an RNDIS/NCM
/// interface (often named “Pixel Tablet”) and a private IPv4. Subnets vary
/// by OEM — not only the classic `192.168.42.0/24`.
///
/// **macOS internet / DNS**
/// Tethering is meant to share the *phone’s* internet, so macOS will:
/// - rank the phone service above Wi‑Fi
/// - install a **default route** via the phone
/// - install **DNS servers** from the phone’s DHCP
///
/// That makes browsers fail to resolve sites even when Wi‑Fi is fine.
/// While OpenDisplay is open we neutralize **only** phone-USB services:
/// 1. Service order: Wi‑Fi/Ethernet above phone USB
/// 2. Phone service: keep link IP/mask, set **router 0.0.0.0** (no default
///    via phone), and pin **DNS to the same servers as Wi‑Fi**
/// 3. Best-effort `route delete -ifscope` if a tether default remains
///
/// OpenDisplay still dials the tablet on the private /24 (source-bound to
/// the tether interface). Prefer **USB debugging + adb** when possible —
/// that path never creates this network service.
enum AndroidTether {

    /// Peer to dial, with the local IPv4 that owns the tether link.
    struct Peer: Equatable {
        let host: String
        let localHost: String
        let interfaceName: String
    }

    enum InternetPreserveResult: Equatable {
        case idle
        case notNeeded
        case reorderedServices
        case neutralized(service: String)
        case demoted(interface: String)
        case failed(detail: String)
    }

    /// True when a phone-USB tether link has an IPv4 (any OEM subnet).
    static func isLikelyPresent() -> Bool {
        !tetherLinks().isEmpty
    }

    static func displayName() -> String? {
        guard isLikelyPresent() else { return nil }
        if let n = phoneUSBServices().first { return "\(n) (tether)" }
        return "Android USB (tether)"
    }

    /// Probe candidate tether peers for an OpenDisplay listener on `port`.
    static func resolvePeer(port: UInt16, timeoutMs: Int = 600) -> Peer? {
        let peers = candidatePeers()
        Log.info("Android USB tether: probing \(peers.count) peer(s) on :\(port) — \(peers.map(\.host).joined(separator: ", "))")
        for peer in peers {
            if probe(peer: peer, port: port, timeoutMs: timeoutMs) {
                Log.info("Android USB tether: reached \(peer.host):\(port) via \(peer.interfaceName) (src \(peer.localHost))")
                return peer
            }
        }
        Log.info("Android USB tether: no peer accepted TCP :\(port) (is OpenDisplay open on the tablet in USB mode?)")
        return nil
    }

    // MARK: - Keep Mac internet + DNS

    /// Call while OpenDisplay is open whenever a phone cable/tether may exist.
    @discardableResult
    static func preservePrimaryInternet() -> InternetPreserveResult {
        var result: InternetPreserveResult = .idle

        switch preferWiFiOverPhoneUSBServices() {
        case .reordered:
            result = .reorderedServices
        case .alreadyOk:
            result = .notNeeded
        case .nothingToDo:
            break
        case .failed(let detail):
            Log.info("Android USB tether: service order failed: \(detail)")
            result = .failed(detail: detail)
        }

        // Neutralize each phone USB service that has a live IPv4 + router/DNS.
        // This is what fixes “browser cannot resolve sites” — phone DHCP DNS
        // and gateway must not stay active for internet.
        for svc in phoneUSBServices() {
            if neutralizePhoneUSBService(svc) {
                result = .neutralized(service: svc)
            }
        }

        // Scoped default-route cleanup if something still prefers the tether if.
        let links = tetherLinks()
        guard !links.isEmpty else { return result == .idle ? .idle : result }

        let tetherNames = Set(links.map(\.name))
        if let info = defaultRouteInfo() {
            let targetIF: String? = {
                if let name = info.interface, tetherNames.contains(name) { return name }
                if let gw = info.gateway,
                   let link = links.first(where: { sameSlash24(gw, $0.address) }) {
                    return link.name
                }
                return nil
            }()
            if let ifName = targetIF {
                let delete = run("/sbin/route", ["-n", "delete", "-ifscope", ifName, "default"])
                if delete.ok {
                    Log.info("Android USB tether: demoted default route on \(ifName)")
                    return .demoted(interface: ifName)
                }
                if let gw = info.gateway, !gw.isEmpty, gw != "0.0.0.0" {
                    let viaGW = run("/sbin/route", ["-n", "delete", "default", gw])
                    if viaGW.ok {
                        Log.info("Android USB tether: removed default via \(gw)")
                        return .demoted(interface: ifName)
                    }
                }
            }
        }

        return result == .idle ? .notNeeded : result
    }

    static let serviceOrderHint =
        "If Mac lost internet/DNS: System Settings → Network → ⋯ → Set Service Order → Wi‑Fi above Pixel Tablet; or turn USB tethering off. Prefer USB debugging + adb."

    /// Keep the USB link for OpenDisplay, but stop using the phone as internet/DNS.
    /// - Sets manual IPv4 with **router 0.0.0.0** (no default via phone)
    /// - Sets DNS to the same servers as Wi‑Fi (so mDNSResponder does not hang
    ///   on unreachable phone DNS from DHCP)
    @discardableResult
    private static func neutralizePhoneUSBService(_ service: String) -> Bool {
        guard let info = serviceInfo(service),
              let ip = info.ip, let mask = info.subnet else { return false }

        let router = info.router ?? ""
        let needsRouterClear = !router.isEmpty && router != "0.0.0.0" && router != "none"
        let wifiDNS = wifiDNSServers()
        let phoneDNS = dnsServers(for: service)
        // DHCP DNS shows as empty in networksetup ("There aren't any…") but
        // still feeds scutil — treat empty as "needs pin to Wi‑Fi DNS".
        let needsDNSPin = phoneDNS != wifiDNS

        guard needsRouterClear || needsDNSPin else { return false }

        if needsRouterClear {
            let r = run("/usr/sbin/networksetup",
                        ["-setmanual", service, ip, mask, "0.0.0.0"])
            if r.ok {
                Log.info("Android USB tether: \(service) → manual \(ip)/\(mask) router 0.0.0.0 (no internet via phone)")
            } else {
                Log.info("Android USB tether: setmanual \(service) failed: \(r.stderr)")
            }
        }

        if !wifiDNS.isEmpty {
            let r = run("/usr/sbin/networksetup",
                        ["-setdnsservers", service] + wifiDNS)
            if r.ok {
                Log.info("Android USB tether: \(service) DNS → \(wifiDNS.joined(separator: ", ")) (match Wi‑Fi)")
            }
        }

        // Phone USB IPv6 often advertises broken DNS/AAAA paths that hang
        // dual-stack browsers even after IPv4 is fixed.
        _ = run("/usr/sbin/networksetup", ["-setv6off", service])

        return true
    }

    private static func wifiDNSServers() -> [String] {
        // Prefer whatever the user configured on Wi‑Fi; fall back to public
        // resolvers so phone-service DNS is never left on DHCP-from-phone.
        let fromWiFi = dnsServers(for: "Wi-Fi")
        if !fromWiFi.isEmpty { return fromWiFi }
        // Some locales use "WiFi"
        let alt = dnsServers(for: "WiFi")
        if !alt.isEmpty { return alt }
        return ["1.1.1.1", "1.0.0.1"]
    }

    private static func dnsServers(for service: String) -> [String] {
        let out = run("/usr/sbin/networksetup", ["-getdnsservers", service]).stdout
        let lower = out.lowercased()
        if lower.contains("aren't any") || lower.contains("there aren") {
            return []
        }
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && ipv4Parts(String($0)) != nil }
    }

    private struct ServiceIPv4 {
        var ip: String?
        var subnet: String?
        var router: String?
    }

    private static func serviceInfo(_ service: String) -> ServiceIPv4? {
        let out = run("/usr/sbin/networksetup", ["-getinfo", service]).stdout
        guard !out.isEmpty else { return nil }
        var info = ServiceIPv4()
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("IP address:"),
               let v = t.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
               !v.isEmpty, v != "none" {
                info.ip = v
            } else if t.hasPrefix("Subnet mask:"),
                      let v = t.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                      !v.isEmpty {
                info.subnet = v
            } else if t.hasPrefix("Router:"),
                      let v = t.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                      !v.isEmpty {
                info.router = v
            }
        }
        return info
    }

    // MARK: - Network service order

    private enum ServiceOrderResult {
        case nothingToDo, alreadyOk, reordered, failed(String)
    }

    private static func isPhoneUSBServiceName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("wi-fi") || n.contains("wifi") || n == "ethernet"
            || n.hasPrefix("ethernet ")
            || n.contains("thunderbolt") || n.contains("bridge")
            || n.contains("icloud") || n.contains("vpn") || n.contains("tailscale") {
            return false
        }
        return n.contains("pixel") || n.contains("android") || n.contains("samsung")
            || n.contains("oneplus") || n.contains("xiaomi") || n.contains("huawei")
            || n.contains("motorola") || n.contains("rndis") || n.contains("usb teth")
            || n.contains("usb lan") || n.contains("phone")
            || (n.contains("usb") && (n.contains("google") || n.contains("tablet")))
            || n.contains("tablet") && (n.contains("pixel") || n.contains("galaxy"))
    }

    private static func isPrimaryInternetServiceName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == "wi-fi" || n == "wifi" || n.hasPrefix("wi-fi")
            || n == "ethernet" || n.hasPrefix("ethernet")
            || n.contains("usb 10/100")
            || n.contains("thunderbolt ethernet")
    }

    private static func allNetworkServices() -> [String] {
        let list = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        var services: [String] = []
        for line in list.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if s.lowercased().contains("asterisk") { continue }
            if s.hasPrefix("*") {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if !s.isEmpty { services.append(s) }
        }
        return services
    }

    private static func phoneUSBServices() -> [String] {
        allNetworkServices().filter { isPhoneUSBServiceName($0) }
    }

    /// Map phone USB service name → BSD device (e.g. "Pixel Tablet" → "en7").
    private static func phoneUSBDevices() -> [String: String] {
        let out = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).stdout
        var map: [String: String] = [:]
        // (1) Pixel Tablet
        // (Hardware Port: Pixel Tablet, Device: en7)
        var pending: String?
        for line in out.split(separator: "\n") {
            let t = String(line).trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^\(\d+\)\s+(.+)$"#, options: .regularExpression) {
                var name = String(t[r])
                if let m = name.range(of: #"^\(\d+\)\s+"#, options: .regularExpression) {
                    name = String(name[m.upperBound...])
                }
                pending = name.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let svc = pending,
               t.contains("Device:"),
               let devRange = t.range(of: "Device:") {
                var dev = String(t[devRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if dev.hasSuffix(")") { dev = String(dev.dropLast()) }
                dev = dev.trimmingCharacters(in: .whitespaces)
                if isPhoneUSBServiceName(svc), !dev.isEmpty {
                    map[svc] = dev
                }
                pending = nil
            }
        }
        return map
    }

    @discardableResult
    private static func preferWiFiOverPhoneUSBServices() -> ServiceOrderResult {
        let services = allNetworkServices()
        guard services.count >= 2 else { return .nothingToDo }

        let phone = services.filter { isPhoneUSBServiceName($0) }
        guard !phone.isEmpty else { return .nothingToDo }

        let primary = services.filter { isPrimaryInternetServiceName($0) }
        let middle = services.filter { !isPhoneUSBServiceName($0) && !isPrimaryInternetServiceName($0) }
        let desired = primary + middle + phone
        guard desired.count == services.count else { return .nothingToDo }
        if services == desired { return .alreadyOk }

        let order = run("/usr/sbin/networksetup", ["-ordernetworkservices"] + desired)
        if order.ok {
            Log.info("Android USB tether: service order → \(desired.joined(separator: ", "))")
            return .reordered
        }
        return .failed(order.stderr.isEmpty ? order.stdout : order.stderr)
    }

    // MARK: - Discovery

    private struct Iface {
        let name: String
        let address: String
        /// DHCP/service router when known (tablet side).
        var gateway: String? = nil
    }

    /// Live tether interfaces: phone USB services with IPv4, or classic subnets.
    private static func tetherLinks() -> [Iface] {
        let ifaces = ipv4Interfaces()
        let byName = Dictionary(uniqueKeysWithValues: ifaces.map { ($0.name, $0) })
        var result: [Iface] = []
        var seen = Set<String>()

        // Prefer authoritative phone USB services (any OEM subnet, e.g. 192.168.170.x).
        for (svc, dev) in phoneUSBDevices() {
            guard let iface = byName[dev] else { continue }
            var link = iface
            if let info = serviceInfo(svc), let r = info.router,
               r != "0.0.0.0", r != "none", !r.isEmpty {
                link.gateway = r
            }
            // After we neutralize router to 0.0.0.0, still probe common tablet
            // addresses on this /24 (Pixel often uses .60).
            if link.gateway == nil, let p = ipv4Parts(iface.address) {
                link.gateway = "\(p.0).\(p.1).\(p.2).60"
            }
            if seen.insert(dev).inserted { result.append(link) }
        }

        // Classic AOSP / RNDIS subnets on non-primary interfaces.
        for iface in ifaces where isClassicTetherInterface(iface) {
            if seen.insert(iface.name).inserted { result.append(iface) }
        }

        // Fallback: secondary private en* (not Wi‑Fi /24) when a phone USB
        // *service* exists — covers OEM subnets our allowlist never listed.
        if result.isEmpty, !phoneUSBServices().isEmpty {
            for iface in secondaryPrivateLinks() where seen.insert(iface.name).inserted {
                result.append(iface)
            }
        }
        return result
    }

    /// Non-primary interfaces with 192.168/10/172 private IPv4, excluding the
    /// same /24 as en0 (so home LAN aliases are ignored).
    private static func secondaryPrivateLinks() -> [Iface] {
        let ifaces = ipv4Interfaces()
        let en0 = ifaces.first(where: { $0.name == "en0" })
        let en0Parts = en0.flatMap { ipv4Parts($0.address) }
        return ifaces.compactMap { iface -> Iface? in
            let name = iface.name
            if name == "en0" || name == "en1" || name == "lo0" { return nil }
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw")
                || name.hasPrefix("bridge") || name.hasPrefix("ap") || name.hasPrefix("gif")
                || name.hasPrefix("stf") || name.hasPrefix("anpi") || name.hasPrefix("vmnet")
                || name.hasPrefix("veth") || name.hasPrefix("docker") { return nil }
            guard let p = ipv4Parts(iface.address) else { return nil }
            let isPrivate =
                (p.0 == 192 && p.1 == 168)
                || (p.0 == 10)
                || (p.0 == 172 && (16...31).contains(p.1))
            guard isPrivate else { return nil }
            if let e = en0Parts, e.0 == p.0 && e.1 == p.1 && e.2 == p.2 { return nil }
            var link = iface
            link.gateway = "\(p.0).\(p.1).\(p.2).60"
            return link
        }
    }

    private static let classicTetherThirdOctets: Set<Int> = [42, 137]

    private static func isClassicTetherInterface(_ iface: Iface) -> Bool {
        let name = iface.name
        if name == "en0" || name == "en1" { return false }
        if name == "lo0" || name.hasPrefix("utun") || name.hasPrefix("awdl")
            || name.hasPrefix("llw") || name.hasPrefix("bridge")
            || name.hasPrefix("ap") || name.hasPrefix("gif")
            || name.hasPrefix("stf") || name.hasPrefix("anpi")
            || name.hasPrefix("vmnet") || name.hasPrefix("veth")
            || name.hasPrefix("docker") || name.hasPrefix("lxc") {
            return false
        }
        guard let p = ipv4Parts(iface.address) else { return false }
        return p.0 == 192 && p.1 == 168 && classicTetherThirdOctets.contains(p.2)
    }

    static func candidatePeers() -> [Peer] {
        var seen = Set<String>()
        var peers: [Peer] = []
        for iface in tetherLinks() {
            guard let parts = ipv4Parts(iface.address) else { continue }
            var hosts: [String] = []
            // Service/DHCP router is the most reliable tablet address.
            if let gw = iface.gateway, gw != iface.address { hosts.append(gw) }
            let c = parts.2
            let a = parts.0
            let b = parts.1
            // Common Android sides on the same /24.
            hosts.append(contentsOf: [
                "\(a).\(b).\(c).1",
                "\(a).\(b).\(c).129",
                "\(a).\(b).\(c).60",   // seen on some Pixel tether DHCP
            ])
            for host in hosts {
                if host == iface.address { continue }
                let key = "\(host)@\(iface.name)"
                guard seen.insert(key).inserted else { continue }
                peers.append(Peer(host: host, localHost: iface.address, interfaceName: iface.name))
            }
        }
        return peers.sorted { $0.host < $1.host }
    }

    static func candidateHosts() -> [String] {
        Array(Set(candidatePeers().map(\.host))).sorted()
    }

    private struct DefaultRoute {
        var interface: String?
        var gateway: String?
    }

    private static func ipv4Interfaces() -> [Iface] {
        var result: [Iface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                  &hostname, socklen_t(hostname.count),
                                  nil, 0, NI_NUMERICHOST)
            guard err == 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            let ip = String(cString: hostname)
            result.append(Iface(name: name, address: ip))
        }
        return result
    }

    private static func ipv4Parts(_ ip: String) -> (Int, Int, Int, Int)? {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return nil }
        return (p[0], p[1], p[2], p[3])
    }

    private static func sameSlash24(_ a: String, _ b: String) -> Bool {
        guard let x = ipv4Parts(a), let y = ipv4Parts(b) else { return false }
        return x.0 == y.0 && x.1 == y.1 && x.2 == y.2
    }

    private static func defaultRouteInfo() -> DefaultRoute? {
        let out = run("/sbin/route", ["-n", "get", "default"]).stdout
        guard !out.isEmpty else { return nil }
        var info = DefaultRoute()
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:"),
               let name = trimmed.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces), !name.isEmpty {
                info.interface = name
            } else if trimmed.hasPrefix("gateway:"),
                      let gw = trimmed.split(separator: ":").last?
                        .trimmingCharacters(in: .whitespaces), !gw.isEmpty {
                info.gateway = gw
            }
        }
        if info.interface == nil && info.gateway == nil { return nil }
        return info
    }

    private struct CmdResult {
        var ok: Bool
        var stdout: String
        var stderr: String
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> CmdResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return CmdResult(ok: false, stdout: "", stderr: error.localizedDescription)
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CmdResult(ok: task.terminationStatus == 0, stdout: stdout,
                         stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Probe (interface-pinned)

    private static func probe(peer: Peer, port: UInt16, timeoutMs: Int) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        let params = NWParameters(tls: nil, tcp: options)
        params.multipathServiceType = .disabled
        params.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(peer.localHost),
            port: 0)

        let conn = NWConnection(
            host: NWEndpoint.Host(peer.host),
            port: nwPort,
            using: params)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ok = true
                conn.cancel()
                sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        _ = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        conn.cancel()
        return ok
    }
}
