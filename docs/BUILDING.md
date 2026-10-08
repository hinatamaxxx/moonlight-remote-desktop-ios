# Building / ソースからのビルド

[日本語ガイド](../README.md) · [User guide](../README.en.md)

このフォークにはMoonlight本体とGo製Tailscaleブリッジが含まれます。ベースのMoonlightだけをビルドしても、このフォークの機能は入りません。

This fork includes Moonlight and a Go Tailscale bridge. Building the upstream Moonlight repository alone does not produce this fork.

## macOS + Xcode

Xcodeと、`TailscaleBridge/go.mod`が指定するGoを用意します。以下のスクリプトはiPhone用の未署名IPAを作成します。ローカルで確認した配布IPAは下記のWindows/WSL経路でビルドしており、このmacOSのIPA生成経路は未確認です。

Install Xcode and the Go version pinned in `TailscaleBridge/go.mod`. The script below produces an unsigned iPhone IPA. The distributed build was validated through the Windows/WSL route below; the macOS IPA packaging path has not been verified.

```sh
git clone --recursive https://github.com/hinatamaxxx/moonlight-remote-desktop-ios.git
cd moonlight-remote-desktop-ios
bash BuildScripts/build-embedded-ipa.sh
```

The output is written to `embedded-build/<timestamp>/`. The script also creates license notices and `SHA256SUMS.txt`.

For Xcode development, first run `bash TailscaleBridge/build-apple.sh`, then open `Moonlight.xcodeproj`. Set your own signing team and bundle identifier if installing directly on a device. Do not commit signing credentials or personal Xcode settings.

## Windows + WSL

[Windows IPAビルドガイド](https://github.com/hinatamaxxx/windows-ipa-build-guide)のMoonlight向け手順を使います。アプリソースにはこのフォークを指定し、ガイドで指定されたSDK・リソースキットを用意してください。

Use the Moonlight instructions in the [Windows IPA build guide](https://github.com/hinatamaxxx/windows-ipa-build-guide), with this fork as the application source. That route requires the SDK and resource kit described in the guide.

## Tailscale bridge checks

```sh
cd TailscaleBridge
go test -race ./...
go vet ./...
```

These checks cover relay behavior. They do not replace an iPhone test through LiveContainer and a real tailnet. The fork's supported release target is iPhone; retained tvOS sources are inherited from upstream.
