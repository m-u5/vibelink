import Foundation

/// An advert from an iPhone this Mac is paired with.
public struct CapturedDevice: Sendable {
    public let hostKey: String
    public let name: String
    public let advert: CapturedAdvert
}

public enum Capture {
    /// Scans for nearby iPhone adverts and keeps those from devices known to devicectl.
    /// Safe to call off the main thread; it does not touch the store.
    public static func scan(seconds: TimeInterval = 5) throws -> [CapturedDevice] {
        let adverts = try RemotePairingScanner.scan(seconds: seconds)
        let devices = (try? CoreDevice.list()) ?? []
        return adverts.compactMap { a in
            // Unknown hosts are other people's devices on the LAN; their adverts are useless to us.
            guard let info = devices.first(where: { $0.hostKey?.caseInsensitiveCompare(a.hostKey) == .orderedSame }) else { return nil }
            return CapturedDevice(hostKey: a.hostKey, name: info.name,
                                  advert: CapturedAdvert(identifier: a.identifier, txt: a.txt, port: a.port, capturedAt: Date()))
        }
    }

    /// Stores captured adverts, links devices that have no peer yet to a matching Tailscale peer,
    /// and returns the keys of the devices that were captured.
    @discardableResult
    public static func save(_ found: [CapturedDevice], to store: DeviceStore, peers: [TailscalePeer]) throws -> [String] {
        for f in found { store.remember(advert: f.advert, hostKey: f.hostKey, name: f.name) }
        let keys = Array(Set(found.map(\.hostKey))).sorted()
        for key in keys {
            guard let d = store.iosDevice(key), d.peerIP == nil, let p = suggestPeer(for: d, peers: peers) else { continue }
            store.link(iosKey: key, peer: p)
        }
        try store.save()
        return keys
    }

    /// Suggests the Tailscale peer for a device by comparing names ("My-iPhone" vs "my-iphone"),
    /// falling back to the only iOS peer when there is exactly one.
    public static func suggestPeer(for device: IOSDevice, peers: [TailscalePeer]) -> TailscalePeer? {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let ios = peers.filter(\.isIOS)
        let target = norm(device.key)
        return ios.first { norm($0.hostName) == target || norm($0.shortDNSName) == target } ?? (ios.count == 1 ? ios[0] : nil)
    }
}
