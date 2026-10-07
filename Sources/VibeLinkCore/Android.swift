import Foundation

/// Connects adb to an Android device over Tailscale.
///
/// adb accepts a plain IP, so no discovery spoofing is needed; only the port must be found:
/// - `adb tcpip 5555` (legacy) listens on 5555 until reboot.
/// - Android 11+ "Wireless debugging" listens on a random port, found here by scanning the peer.
public enum AndroidConnector {
    public static var adb: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] { candidates.insert("\(sdk)/platform-tools/adb", at: 0) }
        return Shell.find(candidates)
    }

    /// Range Android uses for the Wireless debugging (TLS) port.
    public static let wirelessDebuggingPorts = 30000...49999

    /// Port that `pin` switches adbd to; it stays there until the device reboots.
    public static let pinnedPort = 5555

    /// Returns the connected port, or nil. Reuses an existing healthy connection.
    public static func connect(ip: String, preferredPorts: [Int], log: (String) -> Void = { print($0) }) throws -> Int? {
        guard let adb else { throw ShellError.notFound("adb") }
        if let port = connectedPort(ip: ip) { return port }
        let port = try findAndConnect(adb, ip: ip, preferredPorts: preferredPorts, log: log)
        if let port { removeStale(ip: ip, keeping: port) }
        return port
    }

    private static func findAndConnect(_ adb: String, ip: String, preferredPorts: [Int], log: (String) -> Void) throws -> Int? {
        var tried = Set<Int>()
        for port in preferredPorts + [pinnedPort] where tried.insert(port).inserted {
            if try adbConnect(adb, ip: ip, port: port, log: log) { return port }
        }
        log("scanning \(ip) for an adb port…")
        let open = PortScanner.openPorts(ip: ip, ports: wirelessDebuggingPorts)
        log("open ports: \(open.map(String.init).joined(separator: ", "))")
        for port in open where tried.insert(port).inserted {
            if try adbConnect(adb, ip: ip, port: port, log: log) { return port }
        }
        return nil
    }

    /// Restarts adbd on the device in TCP mode on `pinnedPort` (works over the current wireless
    /// connection, no USB needed) and reconnects there. Returns true when connected on the pinned port.
    public static func pin(ip: String, log: (String) -> Void = { print($0) }) throws -> Bool {
        guard let adb else { throw ShellError.notFound("adb") }
        guard let current = connectedPort(ip: ip) else { return false }
        if current == pinnedPort { return true }
        let r = try Shell.run(adb, ["-s", "\(ip):\(current)", "tcpip", String(pinnedPort)], timeout: 15)
        log("adb tcpip \(pinnedPort): \((r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))")
        // adbd restarts; connecting too early can reach the old instance (if it already listened on
        // the pinned port), which then goes offline. Wait, then require the device to stay usable.
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<10 {
            if try adbConnect(adb, ip: ip, port: pinnedPort, log: log) {
                Thread.sleep(forTimeInterval: 1.5)
                if connectedPort(ip: ip) == pinnedPort {
                    removeStale(ip: ip, keeping: pinnedPort)
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// Port of a connection to `ip` that adb reports as usable.
    public static func connectedPort(ip: String) -> Int? {
        serials().first { $0.ip == ip && $0.state == "device" }?.port
    }

    /// Drops connections to `ip` on other ports (left "offline" after the port changed).
    static func removeStale(ip: String, keeping port: Int) {
        guard let adb else { return }
        for s in serials() where s.ip == ip && s.port != port {
            _ = try? Shell.run(adb, ["disconnect", "\(ip):\(s.port)"], timeout: 5)
        }
    }

    static func adbConnect(_ adb: String, ip: String, port: Int, log: (String) -> Void) throws -> Bool {
        guard PortScanner.isOpen(ip: ip, port: port, timeout: 2) else { return false }
        let r = try Shell.run(adb, ["connect", "\(ip):\(port)"], timeout: 15)
        let out = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        log("adb connect \(ip):\(port): \(out)")
        guard out.contains("connected to") else { return false }
        // adb reports "connected" before the TLS handshake; confirm the device is usable.
        let state = try Shell.run(adb, ["-s", "\(ip):\(port)", "get-state"], timeout: 10)
        if state.stdout.contains("device") { return true }
        _ = try? Shell.run(adb, ["disconnect", "\(ip):\(port)"], timeout: 5)
        return false
    }

    public static func disconnect(ip: String, port: Int) throws {
        guard let adb else { throw ShellError.notFound("adb") }
        try Shell.run(adb, ["disconnect", "\(ip):\(port)"], timeout: 10)
    }

    /// Network serials ("ip:port") adb knows about, with their state ("device", "offline", …).
    public static func serials() -> [(ip: String, port: Int, state: String)] {
        guard let adb, let r = try? Shell.run(adb, ["devices"], timeout: 10) else { return [] }
        return parseDevices(r.stdout)
    }

    /// Parses `adb devices` output, keeping only network ("ip:port") serials.
    static func parseDevices(_ output: String) -> [(ip: String, port: Int, state: String)] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { return nil }
            let hp = parts[0].split(separator: ":")
            guard hp.count == 2, let port = Int(hp[1]) else { return nil }
            return (String(hp[0]), port, String(parts[1]))
        }
    }
}

/// Non-blocking TCP connect scanner.
enum PortScanner {
    static func isOpen(ip: String, port: Int, timeout: TimeInterval) -> Bool {
        !openPorts(ip: ip, ports: port...port, timeout: timeout).isEmpty
    }

    static func openPorts(ip: String, ports: ClosedRange<Int>, batch: Int = 1024, timeout: TimeInterval = 2.5) -> [Int] {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return [] }

        var open: [Int] = []
        var start = ports.lowerBound
        while start <= ports.upperBound {
            let end = min(start + batch - 1, ports.upperBound)
            var pending: [(fd: Int32, port: Int)] = []
            for port in start...end {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var a = addr
                a.sin_port = in_port_t(UInt16(port).bigEndian)
                let rc = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if rc == 0 { open.append(port); close(fd) } else if errno == EINPROGRESS { pending.append((fd, port)) } else { close(fd) }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while !pending.isEmpty && Date() < deadline {
                var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                let n = poll(&fds, nfds_t(fds.count), 100)
                guard n > 0 else { continue }
                var still: [(fd: Int32, port: Int)] = []
                for (i, p) in pending.enumerated() {
                    if fds[i].revents == 0 { still.append(p); continue }
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 && fds[i].revents & Int16(POLLOUT) != 0 { open.append(p.port) }
                    close(p.fd)
                }
                pending = still
            }
            pending.forEach { close($0.fd) }
            start = end + 1
        }
        return open.sorted()
    }
}
