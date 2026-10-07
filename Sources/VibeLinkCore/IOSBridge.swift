import Foundation
import Network

/// Makes a remote iPhone look like it is on the local network to Xcode/CoreDevice.
///
/// - Re-advertises a previously captured `_remotepairing._tcp` advert on the primary interface,
///   pointing at this Mac's own address.
/// - Relays the control channel to the iPhone's RemotePairing port over Tailscale.
/// - Pre-opens relays for the dynamic tunnel ports (see `TunnelPortWatcher`).
public final class IOSBridge: @unchecked Sendable {
    public enum Status: Equatable {
        case starting
        case waitingForNetwork
        case running(interface: String, address: String, port: UInt16)
        case failed(String)
    }

    public let device: IOSDevice
    public let peerIP: String
    public private(set) var status: Status = .starting { didSet { if status != oldValue { onStatus?(status) } } }
    public var onStatus: ((Status) -> Void)?

    /// Number of tunnel ports opened ahead of the last one seen.
    static let window = 48

    private let ctl = DispatchQueue(label: "vibelink.ios.ctl")
    private let io = DispatchQueue(label: "vibelink.ios.io")
    private let log: (String) -> Void
    private var control: TCPRelay?
    private var tunnelRelays: [Int: TCPRelay] = [:]
    private let advertiser = ProxyAdvertiser()
    private var watcher: TunnelPortWatcher?
    private var pathMonitor: NWPathMonitor?
    private var current: PrimaryInterface?
    private var allowedPeers: Set<String> = []
    private var advertised: (PrimaryInterface, CapturedAdvert, UInt16)?
    /// Bumped on every teardown so stale timers stop.
    private var generation = 0

    public init(device: IOSDevice, peerIP: String, log: @escaping (String) -> Void = { print($0) }) {
        self.device = device
        self.peerIP = peerIP
        self.log = log
    }

    public func start() {
        ctl.async {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] _ in
                // Let SystemConfiguration settle before reading the new primary interface.
                self?.ctl.asyncAfter(deadline: .now() + 1) { self?.networkChanged() }
            }
            m.start(queue: self.ctl)
            self.pathMonitor = m
            self.bringUp()
        }
    }

    public func stop() {
        ctl.sync {
            pathMonitor?.cancel()
            pathMonitor = nil
            tearDown()
        }
    }

    private func networkChanged() {
        guard pathMonitor != nil, NetworkInfo.primary() != current else { return }
        log("network changed; restarting bridge")
        bringUp()
    }

    private func bringUp() {
        tearDown()
        guard let advert = device.latestAdvert else {
            status = .failed("No captured advert. Connect the iPhone to this Mac's network once and capture it.")
            return
        }
        guard let pri = NetworkInfo.primary() else {
            status = .waitingForNetwork
            return
        }
        current = pri
        allowedPeers = NetworkInfo.allLocalIPv4()
        do {
            let relay = makeRelay(remotePort: advert.port)
            let port = try relay.start(host: pri.ipv4, port: 0)
            control = relay

            // Open tunnel ports before advertising: CoreDevice asks for a tunnel right after the control channel is up.
            let w = TunnelPortWatcher { [weak self] host, port in
                self?.ctl.async { self?.tunnelEndpointSeen(host: host, port: port) }
            }
            try w.start()
            watcher = w
            if let last = TunnelPortWatcher.lastLoggedPort() { openWindow(from: last) }

            advertised = (pri, advert, port)
            try advertise()
            scheduleWatchdog()
            status = .running(interface: pri.name, address: pri.ipv4, port: port)
            log("bridging \(device.name) via \(pri.name) \(pri.ipv4):\(port) -> \(peerIP):\(advert.port)")
        } catch {
            tearDown()
            status = .failed("\(error)")
        }
    }

    private func advertise() throws {
        guard let (pri, advert, port) = advertised else { return }
        try advertiser.start(interfaceIndex: pri.index, instance: advert.identifier,
                             host: "\(device.key)\(proxyHostSuffix).local.", ipv4: pri.ipv4, port: port, txt: advert.txt)
    }

    /// remotepairingd stops retrying an advert after repeated failures (e.g. while Tailscale was down).
    /// Re-registering makes it look like a fresh advert, so do that when the control channel goes quiet.
    private func scheduleWatchdog() {
        let gen = generation
        ctl.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.generation == gen, let control = self.control else { return }
            if Date().timeIntervalSince(control.lastActivity) > 60 {
                self.log("no control channel activity; re-advertising")
                self.advertiser.stop()
                try? self.advertise()
                control.lastActivity = Date()
            }
            self.scheduleWatchdog()
        }
    }

    private func tunnelEndpointSeen(host: String, port: Int) {
        guard let cur = current, host.hasPrefix(cur.ipv4) else { return }
        log("tunnel port \(port) \(tunnelRelays[port] != nil ? "ready" : "missed, retrying")")
        openWindow(from: port)
    }

    /// Ensures relays exist for `base ... base+window` and drops listeners well below `base`.
    private func openWindow(from base: Int) {
        guard let cur = current else { return }
        for p in base...(base + Self.window) where tunnelRelays[p] == nil && p <= 65535 {
            let r = makeRelay(remotePort: UInt16(p))
            // Ports already used on this Mac fail to bind; those are skipped.
            if (try? r.start(host: cur.ipv4, port: UInt16(p))) != nil { tunnelRelays[p] = r }
        }
        for (p, r) in tunnelRelays where p < base - 16 && r.activeConnections == 0 {
            r.stopAll()
            tunnelRelays[p] = nil
        }
    }

    private func makeRelay(remotePort: UInt16) -> TCPRelay {
        TCPRelay(remoteHost: peerIP, remotePort: remotePort, allowedPeers: allowedPeers, queue: io, log: log)
    }

    private func tearDown() {
        generation += 1
        advertised = nil
        watcher?.stop()
        watcher = nil
        advertiser.stop()
        control?.stopAll()
        control = nil
        tunnelRelays.values.forEach { $0.stopAll() }
        tunnelRelays.removeAll()
        current = nil
    }
}

