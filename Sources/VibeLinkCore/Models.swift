import Foundation

/// A `_remotepairing._tcp` advert seen while the iPhone was on the local network.
/// The (identifier, authTag) pair stays valid for the Mac it is paired with, so it can be replayed later.
public struct CapturedAdvert: Codable, Hashable, Sendable {
    public var identifier: String
    /// TXT entries in the original order, as "key=value".
    public var txt: [String]
    public var port: UInt16
    public var capturedAt: Date

    public init(identifier: String, txt: [String], port: UInt16, capturedAt: Date) {
        self.identifier = identifier
        self.txt = txt
        self.port = port
        self.capturedAt = capturedAt
    }
}

public struct IOSDevice: Codable, Hashable, Identifiable, Sendable {
    /// Bonjour host label, e.g. "My-iPhone".
    public var key: String
    public var name: String
    /// Newest first.
    public var adverts: [CapturedAdvert]
    public var peerName: String?
    public var peerIP: String?

    public var id: String { key }
    public var latestAdvert: CapturedAdvert? { adverts.first }

    mutating func remember(_ advert: CapturedAdvert) {
        adverts.removeAll { $0.identifier == advert.identifier }
        adverts.insert(advert, at: 0)
        if adverts.count > 10 { adverts.removeLast(adverts.count - 10) }
    }
}

public struct AndroidDevice: Codable, Hashable, Identifiable, Sendable {
    public var peerName: String
    public var peerIP: String
    public var lastPort: Int?
    /// Reconnect automatically when the Wireless debugging port changes.
    public var autoReconnect: Bool

    public init(peerName: String, peerIP: String, lastPort: Int?, autoReconnect: Bool = true) {
        self.peerName = peerName
        self.peerIP = peerIP
        self.lastPort = lastPort
        self.autoReconnect = autoReconnect
    }

    public var id: String { peerName }
}

public struct StoreData: Codable {
    public var ios: [IOSDevice] = []
    public var android: [AndroidDevice] = []
}

/// Persists devices to ~/Library/Application Support/VibeLink/devices.json.
public final class DeviceStore {
    public private(set) var data: StoreData
    let url: URL

    public init(url: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeLink", isDirectory: true)
        self.url = url ?? dir.appendingPathComponent("devices.json")
        if let d = try? Data(contentsOf: self.url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            data = (try? dec.decode(StoreData.self, from: d)) ?? StoreData()
        } else {
            data = StoreData()
        }
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(data).write(to: url, options: .atomic)
    }

    public func iosDevice(_ key: String) -> IOSDevice? {
        data.ios.first { $0.key.caseInsensitiveCompare(key) == .orderedSame || $0.name == key }
    }

    /// Records a captured advert, creating the device entry if needed.
    public func remember(advert: CapturedAdvert, hostKey: String, name: String) {
        if let i = data.ios.firstIndex(where: { $0.key == hostKey }) {
            data.ios[i].remember(advert)
            data.ios[i].name = name
        } else {
            var d = IOSDevice(key: hostKey, name: name, adverts: [])
            d.remember(advert)
            data.ios.append(d)
        }
    }

    public func link(iosKey: String, peer: TailscalePeer) {
        guard let i = data.ios.firstIndex(where: { $0.key == iosKey }) else { return }
        data.ios[i].peerName = peer.shortDNSName
        data.ios[i].peerIP = peer.ipv4
    }

    public func upsertAndroid(_ device: AndroidDevice) {
        if let i = data.android.firstIndex(where: { $0.peerName == device.peerName }) {
            data.android[i] = device
        } else {
            data.android.append(device)
        }
    }

    public func removeIOS(_ key: String) { data.ios.removeAll { $0.key == key } }
}
