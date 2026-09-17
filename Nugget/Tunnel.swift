import Darwin
import Foundation

// LocalDevVPN compatibility: detect whether a point-to-point tunnel with the
// minimuxer/LocalDevVPN addressing (iface 10.7.1.1, peer 10.7.0.1) is up.
// The tunnel transports lockdown traffic to the emulated network device, so
// the app must NOT start its own em_proxy WireGuard server when a native
// LocalDevVPN (NEPacketTunnelProvider-based) tunnel already provides the
// same loopback plumbing.
enum Tunnel {
    static let ifaceIP = "10.7.1.1"
    static let peerIP = "10.7.0.1"
    static let servicePort: UInt16 = 62078

    // Enumerate interface addresses via getifaddrs and report whether the
    // LocalDevVPN interface IP is configured on any interface.
    static func isInterfaceUp(_ address: String = ifaceIP) -> Bool {
        configure().addresses.contains(address)
    }

    // Mirror SideStore's minimuxer pre-start bootstrap (NetworkObserverService
    // + probeVPNHandshake): the tunnel must be present AND actually route to
    // the emulated peer before core.start() is allowed to run. Our old Rust
    // lib hardcodes 10.7.0.1:62078 and never re-probes, so if start() runs
    // before the VPN routes, it fails (MinimuxerError.CreateDebug = error 3).
    // - Phase 1: wait until the LocalDevVPN iface IP is configured.
    // - Phase 2: TCP-probe the peer service port until it accepts a connect
    //            (this is exactly what minimuxer's test_device_connection and
    //            the em_proxy debug-client path do when start() runs).
    static func waitForTunnel(
        timeout: TimeInterval = 60,
        log: @escaping (String) -> Void = { _ in }
    ) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if isInterfaceUp() { break }
            log("tunnel: waiting for iface \(ifaceIP) to come up…")
            usleep(500_000)
        }
        guard isInterfaceUp() else {
            log("tunnel: FAILED — iface \(ifaceIP) never appeared within \(Int(timeout))s")
            return false
        }
        log("tunnel: iface \(ifaceIP) up, probing \(peerIP):\(servicePort)…")
        while Date().timeIntervalSince(start) < timeout {
            if probePeer(timeout: 2.0) { return true }
            log("tunnel: \(peerIP):\(servicePort) not reachable yet, retrying…")
            usleep(500_000)
        }
        log("tunnel: FAILED — \(peerIP):\(servicePort) unreachable within \(Int(timeout))s")
        return false
    }

    // Non-blocking TCP connect to the minimuxer lockdown service port on the
    // tunnel peer. Returns true only when the connect completes successfully.
    static func probePeer(ip: String = peerIP, port: UInt16 = servicePort, timeout: TimeInterval = 2.0) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = UInt8(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        var flags = fcntl(fd, F_GETFL, 0)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return false }
        var soerr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len)
        return soerr == 0
    }

    // Compose a human-readable status line for the UI when a tunnel is active.
    static func describe() -> String {
        let info = configure()
        var found: [String] = []
        for a in [ifaceIP, peerIP] where info.addresses.contains(a) {
            found.append(a)
        }
        return found.isEmpty ? "tunnel not detected" : "tunnel detected (\(found.joined(separator: ", ")))"
    }

    private struct IfaceInfo {
        var addresses: Set<String> = []
    }

    private static func configure() -> IfaceInfo {
        var info = IfaceInfo()
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return info
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            if let addr = cur.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0,
                               NI_NUMERICHOST) == 0 {
                    info.addresses.insert(String(cString: host))
                }
            }
            cursor = cur.pointee.ifa_next
        }
        return info
    }
}