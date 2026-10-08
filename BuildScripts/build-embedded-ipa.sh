#!/bin/bash
# Creates an unsigned, source-built IPA for import by LiveContainer.
# Requires macOS with Xcode and the Go version pinned in TailscaleBridge/go.mod.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'A full Xcode build requires macOS.' >&2; exit 1; }
stamp=$(date +%Y%m%d-%H%M%S)
out="$PWD/embedded-build/$stamp"
mkdir -p "$out"
(cd TailscaleBridge && go test -race ./...)
bash TailscaleBridge/build-apple.sh iphoneos arm64
xcodebuild -project Moonlight.xcodeproj -scheme Moonlight -configuration Release \
 -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$out/DerivedData" \
 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 \
 IPHONEOS_DEPLOYMENT_TARGET=15.0 build >"$out/xcodebuild.log" 2>&1
app="$out/DerivedData/Build/Products/Release-iphoneos/Moonlight.app"
[[ -f "$app/Moonlight" ]] || { echo "Missing app; see $out/xcodebuild.log" >&2;exit 1; }
mkdir -p "$out/Payload"
ditto "$app" "$out/Payload/Moonlight.app"
# Keep upstream and embedded dependency license notices in the app.
cp LICENSE.txt "$out/Payload/Moonlight.app/Moonlight-LICENSE.txt"
(cd TailscaleBridge && go mod download && go run ./cmd/notices "$out/Payload/Moonlight.app/Tailscale-LICENSES.txt")
(cd "$out" && /usr/bin/zip -qry Moonlight-9.0.2-Tailscale-unsigned.ipa Payload && shasum -a 256 Moonlight-9.0.2-Tailscale-unsigned.ipa > SHA256SUMS.txt)
echo "$out/Moonlight-9.0.2-Tailscale-unsigned.ipa"
