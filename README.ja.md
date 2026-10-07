# VibeLink

[English](README.md)

[Tailscale](https://tailscale.com)経由で、**どのネットワークからでも**iPhone（Xcode）とAndroid（adb）のワイヤレスデバッグができるようにするツールです。

XcodeのワイヤレスデバッグもAndroidの「ワイヤレスデバッグ」も、端末とMacが同じWi‑Fiにいないと使えません。VibeLinkはmacOSのメニューバーアプリ（とCLI）で、両者をtailnet経由でつなぎます。Macを自宅やオフィスに置いたまま、カフェやコワーキングスペースからでも、実機でビルド・実行・ログ確認を続けられます。

> VibeLinkは個人のプロジェクトであり、AppleおよびTailscaleとは提携・承認の関係にありません。

## 動作環境

- macOS 13以降。iOSにはXcode、AndroidにはAndroid SDKのplatform-toolsが必要です。
- Macと端末の両方でTailscaleを動かし、同じtailnetに参加させてください。
- iPhone：iOS 17以降。このMacとワイヤレスデバッグ用にペアリング済みであること（Xcodeの「Connect via network」）。
- Android：Android 11以降。ワイヤレスデバッグがONで、このMacがadbで承認済みであること。

macOS 26.5、Xcode 26.6、iOS 26.6、Android 16で動作を確認しています。

## インストール

```sh
git clone https://github.com/m-u5/vibelink.git
cd vibelink
./scripts/build-app.sh          # build/VibeLink.app と build/vibelink を作る
open build/VibeLink.app
```

アプリはビルドスクリプトでアドホック署名されます。ログイン項目に入れたい場合は `/Applications` に移動してください。初回はmacOSがローカルネットワークへのアクセスを求めるので、許可してください。

## iPhone（Xcode）

1. **iPhoneがMacと同じWi‑Fiにいる間に**、メニューの「Capture nearby iPhones」を押します（または `vibelink capture`）。iPhoneのBonjour広告を記憶し、tailnet上の対応するiOS端末に自動でリンクします。推定が違っていたら、iPhone横のメニューから正しい端末を選び直してください。
2. iPhoneが別のネットワークに移ったら、横のスイッチをONにします（または `vibelink ios My-iPhone`）。
3. XcodeにiPhoneがネットワーク接続の端末として表示されます。あとはいつもどおりビルド・実行・ログ確認ができます。

ONにしたブリッジは、次にアプリを起動したときに自動で再開します。

### 仕組み

- Mac側の `remotepairingd` は、`_remotepairing._tcp` のBonjour広告でiPhoneを見つけます。VibeLinkはiPhoneが近くにいる間にその広告（`identifier` と `authTag`）を記録しておき、離れた後でMacのプライマリインターフェースに再広告します。広告先のアドレスはMac自身です。
- そのアドレスに来た接続（コントロールチャネルとペアリング検証）を、iPhoneのTailscale IPへTCPで中継します。ペアリング鍵は `remotepairingd` から出ず、VibeLinkはバイト列を転送するだけです。
- その後CoreDeviceのトンネルは、iPhoneが実行時に決めるポートへ直接つなぎに来ます。そのポートは `remotepairingd` のログ（`Got tunnel endpoint`）に出て、しかもiPhoneは連番で割り当てます。そこでVibeLinkは `log stream` を監視し、次のポート群を先回りして待ち受けます。

### 制限

- **約40秒ごとに接続が張り直されます。** `remotepairingd` は相手のARPエントリで生存確認をしていて（CoreUtils `CUNetLinkManager`）、Mac自身のアドレスはpermanentエントリのため、約40秒で「到達不能」と判定されます。ビルド・インストール・実行・ログは動きますが、**ブレークポイントで止めて変数を調べるような長いlldbセッションは固まることがあります**。非常に長いインストールも失敗する可能性があります。解消するには本物のARP隣接ノードを持つ仮想ホスト（vmnetとユーザー空間TCPスタックなど）が必要で、それには特権ヘルパーが要ります。コントリビューション歓迎です。
- 再広告はMacの実LANにもマルチキャストされます。ただし他のMacに害はありません。`authTag` はiPhoneとペアリング済みのMacでしか有効にならず、中継もMac自身のアドレスからの接続しか受け付けないためです。
- 遅延に弱いです。Tailscaleの往復が1秒を超える（電波の弱いモバイル回線経由のテザリングなど）と、デバッガのハンドシェイク（6秒でタイムアウト）が失敗することがあります。
- macOSの非公開の挙動に依存しているので、今後のmacOSやXcodeの更新で動かなくなる可能性があります。

## Android（adb）

メニューのAndroid端末の横にある「Connect」を押します（または `vibelink android <peer>`）。

- 前回のポート、`5555` の順に試し、だめなら端末のTailscale IPをスキャンしてワイヤレスデバッグのポートを探します（30000〜49999番、約5秒）。
- **自動再接続**（デフォルトでON）：10秒ごとに接続を確認し、Wi‑Fiの切り替えやスリープでポートが変わっていたら、新しいポートを探してつなぎ直します。「Disconnect」を押すとOFFになります。CLIでは `--watch` です。
- **5555番に固定**（`⋯` メニューの「Pin to port 5555」、CLIでは `--pin`）：今のワイヤレス接続のまま `adb tcpip 5555` を実行し（USB不要）、端末を再起動するまでポートを5555番に固定します。以後、端末が参加するどのネットワークでも5555番が開きますが、知らないPCからの接続には端末側で承認を求められます。再起動したらワイヤレスデバッグを再度ONにしてください。自動再接続が拾うので、もう一度ピン留めできます。

## CLI

```
vibelink capture [seconds]                        近くのiPhoneを記憶する
vibelink peers                                    Tailscaleのピア一覧
vibelink list                                     記憶している端末の一覧
vibelink link <device> <peer>                     iPhoneをTailscaleのピアにリンクする（名前またはIP）
vibelink ios <device>                             iPhoneをブリッジする（Ctrl-Cで停止）
vibelink android <peer> [port] [--pin] [--watch]  Tailscale経由でadb接続する
```

端末の情報は `~/Library/Application Support/VibeLink/devices.json` に保存されます。

## 開発

```sh
swift build
swift test
```

| パス | 内容 |
| --- | --- |
| `Sources/VibeLinkCore` | Bonjourの再広告、TCP中継、トンネルポート監視、adb接続、Tailscale・devicectl連携 |
| `Sources/vibelink` | CLI |
| `Sources/VibeLinkApp` | SwiftUIのメニューバーアプリ |
| `scripts/build-app.sh` | `VibeLink.app` をビルドしてアドホック署名する |

iOSブリッジのデバッグに便利なコマンドです（zshでは `log` が組み込みコマンドなので `/usr/bin/log` を使ってください）。

```sh
/usr/bin/log stream --predicate 'process == "remotepairingd" AND subsystem == "com.apple.dt.remotepairing"'
xcrun devicectl list devices
```

## ライセンス

[MIT](LICENSE)
