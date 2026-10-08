# 内蔵Tailscaleの使い方

[READMEへ戻る](README.md) · [English](#english)

Moonlight Remote Desktop for iPhoneにはTailscaleを内蔵しています。アプリ自身がTailscaleネットワーク（tailnet）に参加するので、iPhoneのTailscaleアプリを接続しなくても利用できます。PC側にはSunshineとTailscaleが必要です。

## PCを追加する

1. PCでSunshineとTailscaleを起動します。
2. Moonlightの「Tailscale」タブで「Tailscaleにログイン」を押し、PCと同じtailnetに参加します。
3. ホームの「＋」→「Tailscaleで追加」を開き、接続するPCを選んで「接続」を押します。一覧にないPCは「アドレスを入力…」からTailscale IPまたは完全な`.ts.net`名を指定できます。
4. 初回はSunshine側でPINを入力してペアリングします。
5. ホームのPCをタップして配信を開始します。

同時に使える内蔵Tailscaleの中継先は1台です。別のPCを選ぶと接続先が切り替わります。

## 状態の確認

Tailscale画面の「接続テスト」で、選択したPCへの接続を確認できます。「診断履歴」は過去の記録です。履歴にあるエラーは、現在の配信が失敗しているという意味ではありません。

接続処理中は進行状況を表示します。「停止」はログイン状態を残して接続を止めます。「ログアウト」はアプリのTailscaleノードをログアウトさせ、次の接続時にログインが必要になります。

PCごとの接続経路はPCの詳細画面で変更できます。「自動」は到達可能なLAN接続を優先し、利用できなければTailscaleを使います。外出先で経路を切り分けたい場合はTailscaleを指定してください。

## 対応する構成

標準ポートを使うSunshineへの接続を対象にしています。旧NVIDIA GameStream、独自ポート、複数PCへの同時接続、Headscale、サブネットルーター経由の接続は、この内蔵機能の対応範囲に含めていません。

Tailscaleのログイン状態はアプリのデータコンテナに保存されます。コンテナを削除すると、アプリ内のログイン状態も失われます。iOSによるバックグラウンド停止やLiveContainerのコンテナ切り替えをまたぐ配信継続は保証していません。

## English

[Back to README](README.en.md)

Embedded Tailscale lets the app join your tailnet without connecting the separate iPhone Tailscale app. The PC still needs Sunshine and Tailscale.

1. Start Sunshine and Tailscale on the PC.
2. Open Moonlight's Tailscale tab, select “Tailscaleにログイン” (log in), and join the same tailnet as the PC.
3. On Home, choose + → Add with Tailscale, select the PC and press “接続” (Connect). Use “アドレスを入力…” to enter a Tailscale IP or full `.ts.net` name if it is not listed.
4. Enter the pairing PIN in Sunshine on the first connection.
5. Tap the PC on Home to start streaming.

The embedded relay connects to one PC at a time. Selecting a different PC changes its destination.

Use “接続テスト” to test the selected PC. “診断履歴” contains past diagnostics; an old error there does not mean that the current stream has failed. Connection operations display progress. Stop keeps the login state; Log Out signs out the app's Tailscale node and requires a new login before reconnecting.

The PC details screen lets you choose its route. Automatic prefers a reachable LAN connection and otherwise uses Tailscale. Select Tailscale explicitly when diagnosing access away from home.

The embedded feature targets Sunshine's standard ports. Legacy NVIDIA GameStream, custom ports, simultaneous connections to multiple PCs, Headscale and subnet-router destinations are outside its supported scope. Login state is stored in the app's data container and is lost if that container is deleted. Streaming across iOS background suspension or LiveContainer container switches is not guaranteed.
