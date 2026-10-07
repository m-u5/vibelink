import Foundation

/// Periodically re-establishes adb connections to Android peers whose port changed
/// (Wireless debugging picks a new random port after Wi-Fi changes, sleep, or toggling).
public final class AndroidAutoReconnect: @unchecked Sendable {
    public enum Event {
        case connected(peerName: String, ip: String, port: Int)
        case searching(peerName: String)
        case notFound(peerName: String)
        case offline(peerName: String)
    }

    private let queue = DispatchQueue(label: "vibelink.android.reconnect")
    private let lock = NSLock()
    private var _devices: [AndroidDevice] = []
    private var timer: DispatchSourceTimer?
    private var lastReported: [String: String] = [:]
    private let interval: TimeInterval
    private let onEvent: (Event) -> Void
    private let log: (String) -> Void

    public init(interval: TimeInterval = 10, log: @escaping (String) -> Void = { _ in }, onEvent: @escaping (Event) -> Void) {
        self.interval = interval
        self.log = log
        self.onEvent = onEvent
    }

    /// Devices to keep connected; only those with `autoReconnect` are acted on.
    public var devices: [AndroidDevice] {
        get { lock.lock(); defer { lock.unlock() }; return _devices }
        set { lock.lock(); _devices = newValue; lock.unlock() }
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs one check now (on the reconnect queue).
    public func checkNow() {
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        let wanted = devices.filter(\.autoReconnect)
        guard !wanted.isEmpty, let peers = try? Tailscale.peers() else { return }
        for d in wanted {
            let peer = peers.first { $0.shortDNSName == d.peerName }
            guard let peer, peer.online, let ip = peer.ipv4 else {
                report(.offline(peerName: d.peerName), key: "offline")
                continue
            }
            if let port = AndroidConnector.connectedPort(ip: ip) {
                report(.connected(peerName: d.peerName, ip: ip, port: port), key: "connected:\(port)")
                continue
            }
            report(.searching(peerName: d.peerName), key: "searching")
            let port = try? AndroidConnector.connect(ip: ip, preferredPorts: [d.lastPort].compactMap { $0 }, log: log)
            if let port {
                report(.connected(peerName: d.peerName, ip: ip, port: port), key: "connected:\(port)")
            } else {
                report(.notFound(peerName: d.peerName), key: "notFound")
            }
        }
    }

    /// Emits only state changes so callers are not flooded every interval.
    private func report(_ e: Event, key: String) {
        let name: String
        switch e {
        case .connected(let n, _, _), .searching(let n), .notFound(let n), .offline(let n): name = n
        }
        guard lastReported[name] != key else { return }
        lastReported[name] = key
        onEvent(e)
    }
}
