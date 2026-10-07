import Foundation
import Network

/// Listens on one local address/port and splices each accepted connection to a fixed remote host/port.
final class TCPRelay {
    let remoteHost: String
    let remotePort: UInt16
    private let allowedPeers: Set<String>
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private var listener: NWListener?
    private var splices: [ObjectIdentifier: Splice] = [:]
    /// Last accept or open connection; read by the bridge watchdog.
    var lastActivity = Date()

    init(remoteHost: String, remotePort: UInt16, allowedPeers: Set<String>, queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.allowedPeers = allowedPeers
        self.queue = queue
        self.log = log
    }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Starts listening and returns the bound port. Must not be called on `queue`.
    func start(host: String, port: UInt16) throws -> UInt16 {
        let params = Self.tcpParameters()
        params.allowLocalEndpointReuse = true
        guard let addr = IPv4Address(host) else { throw RelayError.badAddress(host) }
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(addr), port: nwPort)
        let l = try NWListener(using: params)
        listener = l

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            case .waiting(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        if ready.wait(timeout: .now() + 3) == .timedOut { failure = RelayError.timeout }
        if let failure { l.cancel(); listener = nil; throw failure }
        return l.port?.rawValue ?? port
    }

    private func accept(_ inbound: NWConnection) {
        lastActivity = Date()
        if case .hostPort(let host, _) = inbound.endpoint {
            let peer = "\(host)".components(separatedBy: "%").first ?? ""
            let normalized = peer.hasPrefix("::ffff:") ? String(peer.dropFirst(7)) : peer
            guard allowedPeers.contains(normalized) else {
                log("rejected connection from \(normalized)")
                inbound.cancel()
                return
            }
        }
        let outbound = NWConnection(host: NWEndpoint.Host(remoteHost), port: NWEndpoint.Port(rawValue: remotePort)!,
                                    using: Self.tcpParameters())
        let s = Splice(a: inbound, b: outbound, queue: queue)
        let id = ObjectIdentifier(s)
        splices[id] = s
        s.onClose = { [weak self] in self?.splices[id] = nil }
        s.start()
    }

    func stopAll() {
        listener?.cancel()
        listener = nil
        splices.values.forEach { $0.close() }
        splices.removeAll()
    }

    var activeConnections: Int { splices.count }

    enum RelayError: Error { case badAddress(String), timeout }
}

/// Bidirectional byte pump between two connections.
final class Splice {
    let a: NWConnection, b: NWConnection
    let queue: DispatchQueue
    var onClose: (() -> Void)?
    private var finished = 0
    private var closed = false

    init(a: NWConnection, b: NWConnection, queue: DispatchQueue) {
        self.a = a; self.b = b; self.queue = queue
    }

    func start() {
        a.stateUpdateHandler = { [weak self] s in self?.handle(s) }
        b.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            self.handle(s)
            if case .ready = s {
                self.pump(self.a, self.b)
                self.pump(self.b, self.a)
            }
        }
        a.start(queue: queue)
        b.start(queue: queue)
    }

    private func handle(_ s: NWConnection.State) {
        switch s {
        case .failed, .cancelled: close()
        case .waiting: close()
        default: break
        }
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { err in
                    if err != nil { self.close() } else if isComplete { self.finish(to) } else { self.pump(from, to) }
                })
            } else if error != nil {
                self.close()
            } else if isComplete {
                self.finish(to)
            } else {
                self.pump(from, to)
            }
        }
    }

    private func finish(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        finished += 1
        if finished == 2 { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        a.cancel()
        b.cancel()
        onClose?()
    }
}
