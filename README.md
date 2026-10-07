# VibeLink

[日本語](README.ja.md)

Wireless debugging for your iPhone (Xcode) and Android phone (adb) from **any network**, over [Tailscale](https://tailscale.com).

Xcode's wireless debugging and Android's Wireless debugging only work while the phone and the Mac are on the same Wi‑Fi. VibeLink is a small macOS menu bar app (plus a CLI) that bridges them over your tailnet, so you can keep building, running and reading logs on a real device from a café, a coworking space or a hotel, while your Mac stays at home or the office.

> VibeLink is an independent project. It is not affiliated with or endorsed by Apple or Tailscale.

## Requirements

- macOS 13 or later, with Xcode (iOS) and/or Android SDK platform-tools (Android)
- Tailscale running on the Mac and on the phone, with both on the same tailnet
- iPhone: iOS 17 or later, already paired with this Mac for wireless debugging ("Connect via network" in Xcode)
- Android: Android 11 or later with Wireless debugging enabled, and this Mac already authorized for adb

Tested with macOS 26.5, Xcode 26.6, iOS 26.6 and Android 16.

## Install

```sh
git clone https://github.com/m-u5/vibelink.git
cd vibelink
./scripts/build-app.sh          # builds build/VibeLink.app and build/vibelink
open build/VibeLink.app
```

The app is ad-hoc signed by the build script. Move it to `/Applications` if you want to add it to Login Items. On first use, macOS asks for Local Network access; allow it.

## iPhone (Xcode)

1. **While the iPhone is on the same Wi‑Fi as the Mac**, click **Capture nearby iPhones** in the menu (or run `vibelink capture`). VibeLink remembers the iPhone's Bonjour advert and links it to the matching iOS device on your tailnet. Pick another device from the menu next to the iPhone if the guess is wrong.
2. When the iPhone is on another network, turn on the switch next to it (or run `vibelink ios My-iPhone`).
3. The iPhone shows up in Xcode as a network device. Build, run and read the console as usual.

Bridges you turn on resume automatically the next time the app starts.

### How it works

- On the Mac, `remotepairingd` finds iPhones through `_remotepairing._tcp` Bonjour adverts. VibeLink records the advert (`identifier` and `authTag`) while the iPhone is nearby, and later re-advertises it on the Mac's primary interface, pointing at the Mac's own address.
- Connections to that address (the control channel and pair verification) are relayed over TCP to the iPhone's Tailscale IP. Pairing keys never leave `remotepairingd`; VibeLink only forwards bytes.
- The CoreDevice tunnel then connects to a port the iPhone picks at runtime. `remotepairingd` logs that port (`Got tunnel endpoint`) and the iPhone hands ports out sequentially, so VibeLink watches `log stream` and listens on the next ports ahead of time.

### Limitations

- **The connection is re-established about every 40 seconds.** `remotepairingd` checks that the device is still reachable by looking at its ARP entry (CoreUtils `CUNetLinkManager`). The Mac's own address has a permanent ARP entry, so it is declared unreachable after about 40 seconds. Build, install, run and logs work, but **a long lldb session (stopped at a breakpoint, inspecting variables) can hang**, and very long installs may fail. Fixing this needs a virtual host with a real ARP neighbor (for example vmnet plus a user-space TCP stack), which requires a privileged helper. Contributions welcome.
- The re-advertisement is also multicast on the Mac's real LAN. It is harmless to other Macs: the `authTag` only validates on the Mac the iPhone is paired with, and the relay only accepts connections from the Mac's own addresses.
- High latency hurts. When the Tailscale round trip exceeds about 1 second (for example a phone hotspot on a weak cellular link), the debugger handshake (6 second timeout) can fail.
- This relies on undocumented macOS behavior and may break with future macOS or Xcode releases.

## Android (adb)

Click **Connect** next to the Android device in the menu (or run `vibelink android <peer>`).

- VibeLink tries the last known port, then `5555`, and otherwise scans the device's Tailscale IP for the Wireless debugging port (30000–49999, about 5 seconds).
- **Auto reconnect** (on by default): every 10 seconds VibeLink checks the connection and, if the port changed after a Wi‑Fi switch or sleep, finds the new port and reconnects. **Disconnect** turns it off. CLI: `--watch`.
- **Pin to port 5555** (in the `⋯` menu, CLI: `--pin`): runs `adb tcpip 5555` over the current wireless connection (no USB needed), so the port stays at 5555 until the device reboots. Port 5555 is then open on every network the phone joins, but adb still asks for authorization on the phone for any computer it does not know. After a reboot, turn Wireless debugging on again; auto reconnect picks it up, and you can pin it again.

## CLI

```
vibelink capture [seconds]                        remember nearby iPhones
vibelink peers                                    list Tailscale peers
vibelink list                                     list remembered devices
vibelink link <device> <peer>                     link an iPhone to its Tailscale peer (name or IP)
vibelink ios <device>                             bridge an iPhone (Ctrl-C to stop)
vibelink android <peer> [port] [--pin] [--watch]  adb connect over Tailscale
```

Devices are stored in `~/Library/Application Support/VibeLink/devices.json`.

## Development

```sh
swift build
swift test
```

| Path | Contents |
| --- | --- |
| `Sources/VibeLinkCore` | Bonjour re-advertising, TCP relay, tunnel port watcher, adb connector, Tailscale and devicectl helpers |
| `Sources/vibelink` | CLI |
| `Sources/VibeLinkApp` | SwiftUI menu bar app |
| `scripts/build-app.sh` | Builds and ad-hoc signs `VibeLink.app` |

Useful when debugging the iOS bridge (use `/usr/bin/log`; in zsh, `log` is a builtin):

```sh
/usr/bin/log stream --predicate 'process == "remotepairingd" AND subsystem == "com.apple.dt.remotepairing"'
xcrun devicectl list devices
```

## License

[MIT](LICENSE)
