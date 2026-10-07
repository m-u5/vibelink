import VibeLinkCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage:
  vibelink capture [seconds]          remember nearby iPhones (run while the iPhone is on this Mac's network)
  vibelink peers                      list Tailscale peers
  vibelink list                       list remembered devices
  vibelink link <device> <peer>       link an iPhone to its Tailscale peer (name or IP)
  vibelink ios <device>               bridge an iPhone over Tailscale (Ctrl-C to stop)
  vibelink android <peer> [port]      adb connect to an Android peer over Tailscale
      --pin                             then move adbd to port 5555 so the port stops changing (until reboot)
      --watch                           keep reconnecting when the port changes (Ctrl-C to stop)
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func findPeer(_ query: String, in peers: [TailscalePeer]) -> TailscalePeer? {
    peers.first { $0.ips.contains(query) || $0.shortDNSName.caseInsensitiveCompare(query) == .orderedSame
        || $0.hostName.caseInsensitiveCompare(query) == .orderedSame }
}

let args = Array(CommandLine.arguments.dropFirst())
let store = DeviceStore()

do {
    switch args.first {
    case "capture":
        let secs = args.count > 1 ? TimeInterval(args[1]) ?? 5 : 5
        let keys = try Capture.save(try Capture.scan(seconds: secs), to: store, peers: (try? Tailscale.peers()) ?? [])
        if keys.isEmpty { print("no paired iPhones found on the local network") }
        for key in keys {
            let d = store.iosDevice(key)
            print("captured \(key) -> \(d?.peerName.map { "linked to \($0) (\(d?.peerIP ?? "?"))" } ?? "not linked; use `vibelink link`")")
        }

    case "peers":
        for p in try Tailscale.peers() {
            print("\(p.shortDNSName)\t\(p.os)\t\(p.ipv4 ?? "-")\t\(p.online ? "online" : "offline")")
        }

    case "list":
        for d in store.data.ios {
            let a = d.latestAdvert
            print("iOS \(d.key)\t\(d.name)\tpeer=\(d.peerName ?? "-") \(d.peerIP ?? "")\tadverts=\(d.adverts.count) latest=\(a?.capturedAt.description ?? "-")")
        }
        for d in store.data.android {
            print("Android \(d.peerName)\t\(d.peerIP)\tlastPort=\(d.lastPort.map(String.init) ?? "-")")
        }

    case "link":
        guard args.count == 3 else { fail(usage) }
        guard let d = store.iosDevice(args[1]) else { fail("unknown device \(args[1]); run `vibelink capture` first") }
        guard let p = findPeer(args[2], in: try Tailscale.peers()) else { fail("unknown peer \(args[2])") }
        store.link(iosKey: d.key, peer: p)
        try store.save()
        print("linked \(d.key) -> \(p.shortDNSName) (\(p.ipv4 ?? "?"))")

    case "ios":
        guard args.count == 2 else { fail(usage) }
        guard let d = store.iosDevice(args[1]) else { fail("unknown device \(args[1])") }
        guard let ip = d.peerIP else { fail("\(d.key) is not linked to a Tailscale peer; use `vibelink link`") }
        let bridge = IOSBridge(device: d, peerIP: ip) { print("[\(Date().formatted(date: .omitted, time: .standard))] \($0)") }
        bridge.onStatus = { print("status: \($0)") }
        bridge.start()
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { bridge.stop(); exit(0) }
        src.resume()
        dispatchMain()

    case "android":
        let flags = Set(args.filter { $0.hasPrefix("--") })
        let positional = args.filter { !$0.hasPrefix("--") }
        guard positional.count >= 2 else { fail(usage) }
        guard let p = findPeer(positional[1], in: try Tailscale.peers()), let ip = p.ipv4 else { fail("unknown peer \(positional[1])") }
        let saved = store.data.android.first { $0.peerName == p.shortDNSName }
        let preferred = (positional.count > 2 ? [Int(positional[2])].compactMap { $0 } : []) + [saved?.lastPort].compactMap { $0 }
        guard var port = try AndroidConnector.connect(ip: ip, preferredPorts: preferred) else {
            fail("no adb port answered on \(ip). Turn on Wireless debugging and retry.")
        }
        print("connected \(ip):\(port)")
        if flags.contains("--pin") {
            guard try AndroidConnector.pin(ip: ip) else { fail("could not switch \(ip) to port \(AndroidConnector.pinnedPort)") }
            port = AndroidConnector.pinnedPort
            print("pinned \(ip):\(port) (until the device reboots)")
        }
        store.upsertAndroid(AndroidDevice(peerName: p.shortDNSName, peerIP: ip, lastPort: port))
        try store.save()
        if flags.contains("--watch") {
            let watcher = AndroidAutoReconnect(log: { print($0) }) { e in
                print("[\(Date().formatted(date: .omitted, time: .standard))] \(e)")
                if case .connected(let name, let ip, let port) = e {
                    store.upsertAndroid(AndroidDevice(peerName: name, peerIP: ip, lastPort: port))
                    try? store.save()
                }
            }
            watcher.devices = store.data.android.filter { $0.peerName == p.shortDNSName }
            watcher.start()
            dispatchMain()
        }

    default:
        print(usage)
    }
} catch {
    fail("error: \(error)")
}
