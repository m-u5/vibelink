import VibeLinkCore
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var iosDevices: [IOSDevice] = []
    @Published private(set) var androidPeers: [TailscalePeer] = []
    @Published private(set) var iosPeers: [TailscalePeer] = []
    @Published private(set) var iosStatus: [String: IOSBridge.Status] = [:]
    @Published private(set) var androidStatus: [String: String] = [:]
    @Published private(set) var message: String?
    @Published private(set) var busy = false

    private let store = DeviceStore()
    private var bridges: [String: IOSBridge] = [:]
    private let work = DispatchQueue(label: "vibelink.app.work")
    private var reconnect: AndroidAutoReconnect!

    init() {
        iosDevices = store.data.ios
        reconnect = AndroidAutoReconnect(log: { NSLog("[VibeLink] %@", $0) }) { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        reconnect.devices = store.data.android
        reconnect.start()
        refreshPeers()
        for key in UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [] { setBridge(key, on: true) }
    }

    private static let enabledKey = "enabledBridges"

    private func persistEnabled() {
        UserDefaults.standard.set(Array(bridges.keys), forKey: Self.enabledKey)
    }

    var anyBridgeRunning: Bool { !bridges.isEmpty }

    func refreshPeers() {
        work.async {
            let peers = (try? Tailscale.peers()) ?? []
            let serials = AndroidConnector.serials().filter { $0.state == "device" }
            Task { @MainActor in
                self.iosPeers = peers.filter(\.isIOS)
                self.androidPeers = peers.filter(\.isAndroid)
                for p in self.androidPeers {
                    guard let ip = p.ipv4 else { continue }
                    if let s = serials.first(where: { $0.ip == ip }) {
                        self.androidStatus[p.shortDNSName] = "connected :\(s.port)"
                    } else if self.isAndroidConnected(p) {
                        self.androidStatus[p.shortDNSName] = nil
                    }
                }
            }
        }
    }

    // MARK: iOS

    func capture() {
        busy = true
        message = "Looking for iPhones on this network…"
        work.async {
            let result = Result { try Capture.scan(seconds: 5) }
            let peers = (try? Tailscale.peers()) ?? []
            Task { @MainActor in
                self.busy = false
                do {
                    let keys = try Capture.save(try result.get(), to: self.store, peers: peers)
                    self.iosDevices = self.store.data.ios
                    self.message = keys.isEmpty ? "No paired iPhone found on this network." : "Remembered \(keys.joined(separator: ", "))."
                } catch {
                    self.message = "Capture failed: \(error)"
                }
            }
        }
    }

    func link(_ device: IOSDevice, to peer: TailscalePeer) {
        store.link(iosKey: device.key, peer: peer)
        try? store.save()
        iosDevices = store.data.ios
        if bridges[device.key] != nil { setBridge(device.key, on: false); setBridge(device.key, on: true) }
    }

    func forget(_ device: IOSDevice) {
        setBridge(device.key, on: false)
        store.removeIOS(device.key)
        try? store.save()
        iosDevices = store.data.ios
    }

    func isBridging(_ key: String) -> Bool { bridges[key] != nil }

    func setBridge(_ key: String, on: Bool) {
        if on {
            guard bridges[key] == nil, let d = store.iosDevice(key) else { return }
            guard let ip = d.peerIP else { message = "Link \(d.name) to its Tailscale device first."; return }
            let b = IOSBridge(device: d, peerIP: ip) { NSLog("[VibeLink] %@", $0) }
            b.onStatus = { s in Task { @MainActor in self.iosStatus[key] = s } }
            bridges[key] = b
            iosStatus[key] = .starting
            b.start()
        } else if let b = bridges.removeValue(forKey: key) {
            work.async { b.stop() }
            iosStatus[key] = nil
        }
        persistEnabled()
    }

    /// Stops bridges on quit without clearing which ones should resume next launch.
    func stopAll() {
        bridges.values.forEach { $0.stop() }
        reconnect.stop()
    }

    // MARK: Android

    func isAndroidConnected(_ peer: TailscalePeer) -> Bool {
        androidStatus[peer.shortDNSName]?.hasPrefix("connected") == true
    }

    func isAutoReconnect(_ peer: TailscalePeer) -> Bool {
        store.data.android.first { $0.peerName == peer.shortDNSName }?.autoReconnect ?? false
    }

    func setAutoReconnect(_ peer: TailscalePeer, _ on: Bool) {
        guard let ip = peer.ipv4 else { return }
        var d = store.data.android.first { $0.peerName == peer.shortDNSName }
            ?? AndroidDevice(peerName: peer.shortDNSName, peerIP: ip, lastPort: nil)
        d.autoReconnect = on
        saveAndroid(d)
        if on { reconnect.checkNow() }
    }

    private func saveAndroid(_ d: AndroidDevice) {
        store.upsertAndroid(d)
        try? store.save()
        reconnect.devices = store.data.android
        objectWillChange.send()
    }

    private func handle(_ e: AndroidAutoReconnect.Event) {
        switch e {
        case .connected(let name, let ip, let port):
            androidStatus[name] = "connected :\(port)"
            if var d = store.data.android.first(where: { $0.peerName == name }), d.lastPort != port || d.peerIP != ip {
                d.lastPort = port
                d.peerIP = ip
                saveAndroid(d)
            }
        case .searching(let name): androidStatus[name] = "port changed, searching…"
        case .notFound(let name): androidStatus[name] = "waiting for Wireless debugging"
        case .offline(let name): androidStatus[name] = nil
        }
    }

    /// Connects now and keeps the device connected from then on.
    func connectAndroid(_ peer: TailscalePeer) {
        guard let ip = peer.ipv4 else { return }
        let name = peer.shortDNSName
        androidStatus[name] = "connecting…"
        let saved = store.data.android.first { $0.peerName == name }
        work.async {
            let result = Result { try AndroidConnector.connect(ip: ip, preferredPorts: [saved?.lastPort].compactMap { $0 }) { NSLog("[VibeLink] %@", $0) } }
            Task { @MainActor in
                switch result {
                case .success(let port?):
                    self.saveAndroid(AndroidDevice(peerName: name, peerIP: ip, lastPort: port, autoReconnect: true))
                    self.androidStatus[name] = "connected :\(port)"
                    self.message = "adb connected to \(name) (\(ip):\(port))."
                case .success(nil):
                    self.androidStatus[name] = "no adb port"
                    self.message = "\(name): turn on Wireless debugging and retry."
                case .failure(let e):
                    self.androidStatus[name] = "failed"
                    self.message = "\(name): \(e)"
                }
            }
        }
    }

    /// Disconnects and stops auto-reconnecting, otherwise it would come straight back.
    func disconnectAndroid(_ peer: TailscalePeer) {
        guard let ip = peer.ipv4 else { return }
        setAutoReconnect(peer, false)
        work.async {
            if let port = AndroidConnector.connectedPort(ip: ip) { try? AndroidConnector.disconnect(ip: ip, port: port) }
            Task { @MainActor in self.androidStatus[peer.shortDNSName] = nil }
        }
    }

    /// Moves adbd to port 5555 so the port stops changing (until the device reboots).
    func pinAndroid(_ peer: TailscalePeer) {
        guard let ip = peer.ipv4 else { return }
        let name = peer.shortDNSName
        androidStatus[name] = "switching to :\(AndroidConnector.pinnedPort)…"
        work.async {
            let ok = (try? AndroidConnector.pin(ip: ip) { NSLog("[VibeLink] %@", $0) }) ?? false
            Task { @MainActor in
                if ok {
                    self.saveAndroid(AndroidDevice(peerName: name, peerIP: ip, lastPort: AndroidConnector.pinnedPort, autoReconnect: true))
                    self.androidStatus[name] = "connected :\(AndroidConnector.pinnedPort)"
                    self.message = "\(name) now listens on \(AndroidConnector.pinnedPort) until it reboots."
                } else {
                    self.androidStatus[name] = nil
                    self.message = "\(name): could not switch to port \(AndroidConnector.pinnedPort)."
                    self.reconnect.checkNow()
                }
            }
        }
    }
}

extension IOSBridge.Status {
    var label: String {
        switch self {
        case .starting: return "starting…"
        case .waitingForNetwork: return "waiting for network"
        case .running(let iface, _, _): return "bridging on \(iface)"
        case .failed(let e): return "error: \(e)"
        }
    }
}
