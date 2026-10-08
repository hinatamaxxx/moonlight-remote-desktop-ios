# Moonlight Remote Desktop for iPhone

[English](README.en.md) · [ダウンロード](https://github.com/hinatamaxxx/moonlight-remote-desktop-ios/releases) · [Tailscaleの使い方](README-Tailscale.md)

iPhoneからPCのデスクトップを操作するために、[Moonlight iOS](https://github.com/moonlight-stream/moonlight-ios)を調整したフォークです。PC画面を縦向きで見ながらトラックパッドで操作し、iPhoneのキーボードで日本語を変換してから送信できます。

ゲーム配信を目的とした元の画面構成を、スマートフォンでの日常的なPC操作に合わせて変更しました。画面上のゲームパッド操作とアプリ一覧のグリッドを外し、PCを選ぶとデスクトップへ接続する構成にしています。

Moonlight公式の配布版ではありません。このフォークの不具合や要望は、[このリポジトリのIssues](https://github.com/hinatamaxxx/moonlight-remote-desktop-ios/issues)へお願いします。

## 主な変更

- 縦画面ではPC映像の下にトラックパッドを配置。2本指タップで右クリック、2本指でスクロールできます。
- 手のマークで「映像を移動」と「PCのタッチ操作」を切り替え。映像の拡大・移動と位置のリセットに対応しています。
- 配信映像の縦横比に合わせて表示。16:10の画面にも対応し、全画面の配信を停止すると縦向きのホームへ戻ります。
- 日本語はiPhoneの入力欄で変換・修正し、「送信」でまとめてPCへ渡します。入力欄が空のときの削除キーはPCへ送ります。
- Esc、Tab、Ctrl、Alt、矢印などのPC用キーを表示できます。
- 横画面でキーボードに合わせて映像を上へ移す設定を追加。キーボードを閉じると元の表示位置へ戻ります。
- Tailscaleを内蔵。iPhoneのTailscaleアプリを別途接続しなくても、外出先から同じTailscaleネットワークのPCへ接続できます。

## 必要なもの

- iPhoneと、セットアップ済みの[LiveContainer](https://livecontainer.github.io/)
- [Sunshine](https://github.com/LizardByte/Sunshine)を実行しているPC
- 外出先から接続する場合は、PC側の[Tailscale](https://tailscale.com/download)とTailscaleアカウント

実機で確認した環境は、iOS 27.0.1、LiveContainer 3.8.0、WindowsのSunshine 2026.516.143833です。内蔵Tailscaleによるモバイル通信での配信と、Copilot Keyboardを使用した日本語入力を確認しています。iPad、tvOS、他のOS・IMEでの動作は未確認です。

## インストールと接続

1. [Releases](https://github.com/hinatamaxxx/moonlight-remote-desktop-ios/releases)から、このフォークの`unsigned.ipa`をダウンロードします。App Store版Moonlightとは異なります。
2. LiveContainerの「＋」からIPAを取り込み、Moonlightを起動します。配布IPAは未署名です。LiveContainer自体の導入は[公式ガイド](https://livecontainer.github.io/)を参照してください。
3. PCでSunshineを起動し、配信するアプリとして`Desktop`を用意します。セットアップは[Sunshineのガイド](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html)を参照してください。
4. 同じWi-Fiなら、ホームのPC一覧からPCを選びます。見つからない場合は「＋」→「IPアドレスで追加」を使います。外出先から使う場合は[Tailscaleの手順](README-Tailscale.md)でPCを追加します。
5. 初回は表示されたPINをPC側のSunshineで入力し、ペアリングします。
6. PCをタップすると配信を開始します。実行中の配信があれば再開し、なければ`Desktop`を開きます。`Desktop`がない場合は先頭のアプリを開くため、デスクトップ操作には`Desktop`を登録してください。

## 日本語入力

キーボードのボタンを押し、入力欄で文章を作ります。予測候補や変換を確定してから「送信」を押してください。下書きはキーボードを閉じても残ります。

「文字送信時にPCのIMEをOFF」は初期状態でONです。「送信」を押すとWindowsへIME OFFを送り、続けて文字列を送ります。PC側で二重に日本語変換されることを避けるための設定です。送信後もPCのIMEは「A」のままです。

Windows以外のPCでは、この設定をOFFにしてください。入力が欠ける場合は、送信先の入力欄を選んだ状態でPCのIMEが「A」になっているか確認してください。アプリからPC側のIME状態を取得する機能はありません。

入力欄に文字がある間、削除キーはiPhone側の下書きだけを削除します。最後の1文字を消した操作ではPC側を削除せず、空になってからの削除キーをPCへ送ります。長押しするとPC側も連続で削除し、指を離すと止まります。

## 操作の設定

「開始時に映像移動をON」は初期状態でONです。配信映像へのタッチでPCを操作したいときは、手のマークで切り替えてください。映像の下にあるトラックパッドは、そのままPC操作に使えます。

横画面でキーボードを開いたときに映像を上へ移したい場合は、設定の「横画面でキーボードに合わせて映像を上へ移動」をONにします。キーボードを表示したまま画面を回転できます。

## 更新・保存データ

更新時は新しいIPAをLiveContainerへ取り込みます。既存の接続情報を使う場合は、同じデータコンテナを選んでください。コンテナの削除や初期化をすると、アプリ内の設定やペアリング情報が失われます。

PCとのペアリング情報、接続先、アプリ内Tailscaleのログイン状態は端末のアプリデータに保存されます。Tailscale接続にはTailscaleのサービスを利用します。入力内容は配信先のPCへ送られ、文字送信の診断ログには本文を含めません。

利用をやめる場合は、Tailscale画面でログアウトしてからLiveContainer内のアプリと不要なデータコンテナを削除します。必要に応じて、PCのSunshineからペアリングも削除してください。

## 対応範囲

配布対象はLiveContainerで使うiPhone版です。アプリをバックグラウンドへ移した後の配信継続や、すべてのPCアプリ・IMEでの文字入力は保証していません。内蔵Tailscaleは標準ポートのSunshineを使う構成が対象です。詳しくは[Tailscaleの使い方](README-Tailscale.md)を参照してください。

## ベースとライセンス

Moonlight iOS 9.0.2をベースにしています。フォークのリリースタグは`v9.0.2-rd.1`のように区別します。アプリ内の名前・ベースバージョンはMoonlight / 9.0.2と表示されます。

Moonlightとこのフォークのソースは[GPL-3.0](LICENSE.txt)で公開しています。Moonlight、Sunshine、Tailscale、LiveContainerと、それぞれの開発者に感謝します。各依存ライブラリにはそれぞれのライセンスが適用されます。IPA内にもMoonlightと内蔵Tailscale依存のライセンス表記を含めています。

このフォークの開発にはOpenAI Codex（GPT-6 Astra、推論設定Low / Medium / High）とClaudeを利用しました。

ソースからのビルドは[ビルド手順](docs/BUILDING.md)を参照してください。
