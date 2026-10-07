import Foundation
import dnssd

public let remotePairingServiceType = "_remotepairing._tcp"
/// Suffix of the host names we register; adverts with it are our own and never captured.
public let proxyHostSuffix = "-vibelink"

public struct ObservedAdvert {
    public let identifier: String
    public let host: String
    public let hostKey: String
    public let port: UInt16
    public let txt: [String]
    public let interfaceIndex: UInt32
}

func parseTXT(_ ptr: UnsafePointer<UInt8>?, _ len: Int) -> [String] {
    guard let ptr, len > 0 else { return [] }
    var out: [String] = []
    var i = 0
    while i < len {
        let n = Int(ptr[i]); i += 1
        guard i + n <= len else { break }
        if n > 0 { out.append(String(decoding: UnsafeBufferPointer(start: ptr + i, count: n), as: UTF8.self)) }
        i += n
    }
    return out
}

func encodeTXT(_ entries: [String]) -> Data {
    var d = Data()
    for e in entries {
        let b = Data(e.utf8).prefix(255)
        d.append(UInt8(b.count))
        d.append(b)
    }
    return d
}

/// Browses `_remotepairing._tcp` and resolves each instance, reporting real device adverts.
public final class RemotePairingScanner {
    private var conn: DNSServiceRef?
    private var resolving = Set<String>()
    private let queue = DispatchQueue(label: "vibelink.scanner")
    private let onAdvert: (ObservedAdvert) -> Void

    public init(onAdvert: @escaping (ObservedAdvert) -> Void) {
        self.onAdvert = onAdvert
    }

    public func start() throws {
        var c: DNSServiceRef?
        guard DNSServiceCreateConnection(&c) == kDNSServiceErr_NoError, let c else { throw ScanError.dnssd("connection") }
        conn = c
        var browse: DNSServiceRef? = c
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceBrowse(&browse, DNSServiceFlags(kDNSServiceFlagsShareConnection), 0, remotePairingServiceType, "local.", { _, flags, ifIndex, err, name, type, domain, ctx in
            guard err == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  ifIndex != kDNSServiceInterfaceIndexLocalOnly,
                  let ctx, let name, let type, let domain else { return }
            let me = Unmanaged<RemotePairingScanner>.fromOpaque(ctx).takeUnretainedValue()
            me.resolve(name: String(cString: name), type: String(cString: type), domain: String(cString: domain), ifIndex: ifIndex)
        }, ctx)
        guard err == kDNSServiceErr_NoError else { throw ScanError.dnssd("browse \(err)") }
        DNSServiceSetDispatchQueue(c, queue)
    }

    private func resolve(name: String, type: String, domain: String, ifIndex: UInt32) {
        let key = "\(name)|\(ifIndex)"
        guard let conn, !resolving.contains(key) else { return }
        resolving.insert(key)
        var ref: DNSServiceRef? = conn
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DNSServiceResolve(&ref, DNSServiceFlags(kDNSServiceFlagsShareConnection), ifIndex, name, type, domain, { _, _, ifIndex, err, _, host, port, txtLen, txt, ctx in
            guard err == kDNSServiceErr_NoError, let ctx, let host else { return }
            let me = Unmanaged<RemotePairingScanner>.fromOpaque(ctx).takeUnretainedValue()
            let hostStr = String(cString: host)
            let entries = parseTXT(txt, Int(txtLen))
            let hostKey = hostStr.components(separatedBy: ".").first ?? hostStr
            guard !hostKey.hasSuffix(proxyHostSuffix),
                  let ident = entries.first(where: { $0.hasPrefix("identifier=") })?.dropFirst("identifier=".count),
                  entries.contains(where: { $0.hasPrefix("authTag=") }) else { return }
            me.onAdvert(ObservedAdvert(identifier: String(ident), host: hostStr, hostKey: hostKey,
                                       port: UInt16(bigEndian: port), txt: entries, interfaceIndex: ifIndex))
        }, ctx)
    }

    public func stop() {
        queue.sync {
            if let conn { DNSServiceRefDeallocate(conn) }
            conn = nil
        }
    }

    public enum ScanError: Error { case dnssd(String) }

    /// Scans for `seconds` and returns unique adverts.
    public static func scan(seconds: TimeInterval) throws -> [ObservedAdvert] {
        var found: [String: ObservedAdvert] = [:]
        let lock = NSLock()
        let s = RemotePairingScanner { a in lock.lock(); found[a.identifier] = a; lock.unlock() }
        try s.start()
        Thread.sleep(forTimeInterval: seconds)
        s.stop()
        lock.lock(); defer { lock.unlock() }
        return Array(found.values)
    }
}

/// Registers a `_remotepairing._tcp` service plus an A record on a single interface.
public final class ProxyAdvertiser {
    private var conn: DNSServiceRef?
    private let queue = DispatchQueue(label: "vibelink.advertiser")

    public init() {}

    public func start(interfaceIndex: UInt32, instance: String, host: String, ipv4: String, port: UInt16, txt: [String]) throws {
        stop()
        var c: DNSServiceRef?
        guard DNSServiceCreateConnection(&c) == kDNSServiceErr_NoError, let c else { throw RegisterError.dnssd("connection", 0) }

        var addr = in_addr()
        guard inet_pton(AF_INET, ipv4, &addr) == 1 else { DNSServiceRefDeallocate(c); throw RegisterError.badAddress(ipv4) }
        var rec: DNSRecordRef?
        let e1 = withUnsafeBytes(of: &addr) { buf in
            DNSServiceRegisterRecord(c, &rec, DNSServiceFlags(kDNSServiceFlagsUnique), interfaceIndex, host,
                                     UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, buf.baseAddress, 120,
                                     { _, _, _, _, _ in }, nil)
        }
        guard e1 == kDNSServiceErr_NoError else { DNSServiceRefDeallocate(c); throw RegisterError.dnssd("A record", e1) }

        let txtData = encodeTXT(txt)
        var svc: DNSServiceRef? = c
        let e2 = txtData.withUnsafeBytes { t in
            DNSServiceRegister(&svc, DNSServiceFlags(kDNSServiceFlagsShareConnection | kDNSServiceFlagsNoAutoRename), interfaceIndex,
                               instance, remotePairingServiceType, "local.", host, port.bigEndian,
                               UInt16(txtData.count), t.baseAddress, { _, _, _, _, _, _, _ in }, nil)
        }
        guard e2 == kDNSServiceErr_NoError else { DNSServiceRefDeallocate(c); throw RegisterError.dnssd("service", e2) }
        DNSServiceSetDispatchQueue(c, queue)
        conn = c
    }

    public func stop() {
        queue.sync {
            if let conn { DNSServiceRefDeallocate(conn) }
            conn = nil
        }
    }

    public enum RegisterError: Error { case dnssd(String, DNSServiceErrorType), badAddress(String) }
}
