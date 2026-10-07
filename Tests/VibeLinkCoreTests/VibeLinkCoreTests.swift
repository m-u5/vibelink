import Foundation
@testable import VibeLinkCore
import XCTest

final class BonjourTests: XCTestCase {
    func testTXTRoundTrip() {
        let entries = ["identifier=ABC", "authTag=tsrp/RFd", "ver=24", "minVer=8", "flags=0"]
        let data = encodeTXT(entries)
        let decoded = data.withUnsafeBytes { parseTXT($0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        XCTAssertEqual(decoded, entries)
    }

    func testParseTXTIgnoresTruncatedEntry() {
        let bytes: [UInt8] = [3, 0x61, 0x3D, 0x62, 9, 0x63]
        XCTAssertEqual(parseTXT(bytes, bytes.count), ["a=b"])
    }
}

final class TunnelPortWatcherTests: XCTestCase {
    func testParsesTunnelEndpoint() {
        let line = "2026-10-06 11:19:52.379 Df remotepairingd[1411:1d4f8133] [com.apple.dt.remotepairing:networktunnelmanager] tunnel-6177: Got tunnel endpoint: '192.168.0.155%en1:54576'"
        let parsed = TunnelPortWatcher.parse(line)
        XCTAssertEqual(parsed?.0, "192.168.0.155%en1")
        XCTAssertEqual(parsed?.1, 54576)
    }

    func testIgnoresOtherLines() {
        XCTAssertNil(TunnelPortWatcher.parse("remotepairingd: Tunnel connection established"))
    }
}

final class TailscaleTests: XCTestCase {
    func testParsesPeers() throws {
        let json = """
        {"Peer": {
          "a": {"ID": "1", "HostName": "iPhone", "DNSName": "my-iphone.tail1234.ts.net.", "OS": "iOS",
                "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"], "Online": true},
          "b": {"ID": "2", "HostName": "pixel", "DNSName": "pixel.tail1234.ts.net.", "OS": "android",
                "TailscaleIPs": ["100.64.0.3"], "Online": false}
        }}
        """
        let peers = try Tailscale.parse(Data(json.utf8))
        XCTAssertEqual(peers.map(\.shortDNSName), ["my-iphone", "pixel"])
        XCTAssertEqual(peers[0].ipv4, "100.64.0.2")
        XCTAssertTrue(peers[0].isIOS)
        XCTAssertTrue(peers[1].isAndroid)
        XCTAssertFalse(peers[1].online)
    }
}

final class AndroidTests: XCTestCase {
    func testParsesNetworkSerialsOnly() {
        let output = """
        List of devices attached
        100.64.0.3:5555\tdevice
        100.64.0.3:41234\toffline
        R5CT1234ABC\tdevice

        """
        let serials = AndroidConnector.parseDevices(output)
        XCTAssertEqual(serials.count, 2)
        XCTAssertEqual(serials[0].ip, "100.64.0.3")
        XCTAssertEqual(serials[0].port, 5555)
        XCTAssertEqual(serials[0].state, "device")
        XCTAssertEqual(serials[1].state, "offline")
    }
}

final class CaptureTests: XCTestCase {
    private func peer(_ name: String, os: String = "iOS") -> TailscalePeer {
        TailscalePeer(id: name, hostName: name, dnsName: "\(name).tail1234.ts.net.", os: os, ips: ["100.64.0.9"], online: true)
    }

    private func device(_ key: String) -> IOSDevice {
        IOSDevice(key: key, name: key, adverts: [])
    }

    func testSuggestsPeerByName() {
        let peers = [peer("work-iphone"), peer("my-iphone"), peer("my-iphone-android", os: "android")]
        XCTAssertEqual(Capture.suggestPeer(for: device("My-iPhone"), peers: peers)?.hostName, "my-iphone")
    }

    func testFallsBackToOnlyIOSPeer() {
        let peers = [peer("iphone-1"), peer("pixel", os: "android")]
        XCTAssertEqual(Capture.suggestPeer(for: device("My-iPhone"), peers: peers)?.hostName, "iphone-1")
    }

    func testNoSuggestionWhenAmbiguous() {
        XCTAssertNil(Capture.suggestPeer(for: device("My-iPhone"), peers: [peer("a"), peer("b")]))
    }
}

final class StoreTests: XCTestCase {
    func testRememberKeepsNewestFirstWithoutDuplicates() {
        var d = IOSDevice(key: "My-iPhone", name: "My iPhone", adverts: [])
        let a = CapturedAdvert(identifier: "A", txt: [], port: 49152, capturedAt: Date())
        let b = CapturedAdvert(identifier: "B", txt: [], port: 49152, capturedAt: Date())
        d.remember(a)
        d.remember(b)
        d.remember(a)
        XCTAssertEqual(d.adverts.map(\.identifier), ["A", "B"])
    }

    func testSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibelink-test-\(UUID().uuidString)/devices.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = DeviceStore(url: url)
        store.remember(advert: CapturedAdvert(identifier: "A", txt: ["identifier=A", "authTag=x"], port: 49152, capturedAt: Date()),
                       hostKey: "My-iPhone", name: "My iPhone")
        store.upsertAndroid(AndroidDevice(peerName: "pixel", peerIP: "100.64.0.3", lastPort: 5555, autoReconnect: false))
        try store.save()

        let loaded = DeviceStore(url: url)
        XCTAssertEqual(loaded.iosDevice("my-iphone")?.latestAdvert?.txt, ["identifier=A", "authTag=x"])
        XCTAssertEqual(loaded.data.android.first?.lastPort, 5555)
        XCTAssertEqual(loaded.data.android.first?.autoReconnect, false)
    }
}
