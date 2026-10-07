import VibeLinkCore
import SwiftUI

@main
struct VibeLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Quit cleanly on SIGTERM too, so bridges and their `log stream` children are stopped.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopAll()
    }
}

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.anyBridgeRunning ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VibeLink").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refreshPeers() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh Tailscale peers")
            }

            Text("iPhone (Xcode)").font(.subheadline).foregroundStyle(.secondary)
            if model.iosDevices.isEmpty {
                Text("No iPhone remembered yet. Put the iPhone on this Mac's Wi‑Fi, then capture it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.iosDevices) { d in IOSRow(model: model, device: d) }
            Button("Capture nearby iPhones") { model.capture() }.disabled(model.busy)

            Divider()

            Text("Android (adb)").font(.subheadline).foregroundStyle(.secondary)
            if model.androidPeers.isEmpty {
                Text("No Android devices on your tailnet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.androidPeers) { p in AndroidRow(model: model, peer: p) }

            if let m = model.message {
                Divider()
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit VibeLink") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 340)
    }
}

struct IOSRow: View {
    @ObservedObject var model: AppModel
    let device: IOSDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { model.isBridging(device.key) },
                                     set: { model.setBridge(device.key, on: $0) })) {
                    Text(device.name).fontWeight(.medium)
                }
                .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Menu {
                    ForEach(model.iosPeers) { p in
                        Button("\(p.shortDNSName) (\(p.ipv4 ?? "-"))\(p.online ? "" : " – offline")") { model.link(device, to: p) }
                    }
                    Divider()
                    Button("Forget \(device.name)", role: .destructive) { model.forget(device) }
                } label: { Text(device.peerName ?? "Link…") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Text(model.iosStatus[device.key]?.label ?? captureInfo)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var captureInfo: String {
        guard let a = device.latestAdvert else { return "not captured" }
        return "captured \(a.capturedAt.formatted(.relative(presentation: .named)))"
    }
}

struct AndroidRow: View {
    @ObservedObject var model: AppModel
    let peer: TailscalePeer

    var body: some View {
        HStack {
            Circle().fill(peer.online ? Color.green : Color.secondary).frame(width: 7, height: 7)
            VStack(alignment: .leading) {
                Text(peer.shortDNSName).fontWeight(.medium)
                Text(model.androidStatus[peer.shortDNSName] ?? (peer.ipv4 ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isAndroidConnected(peer) {
                Button("Disconnect") { model.disconnectAndroid(peer) }
            } else {
                Button("Connect") { model.connectAndroid(peer) }.disabled(!peer.online)
            }
            Menu {
                Toggle("Auto reconnect", isOn: Binding(get: { model.isAutoReconnect(peer) },
                                                        set: { model.setAutoReconnect(peer, $0) }))
                Button("Pin to port \(AndroidConnector.pinnedPort)") { model.pinAndroid(peer) }
                    .disabled(!model.isAndroidConnected(peer))
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}
