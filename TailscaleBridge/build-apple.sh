#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sdk=${1:-iphoneos}
arch=${2:-arm64}
case "$sdk:$arch" in
 iphoneos:arm64) target=arm64-apple-ios15.0; goos=ios ;;
 iphonesimulator:arm64) target=arm64-apple-ios15.0-simulator; goos=ios ;;
 iphonesimulator:amd64) target=x86_64-apple-ios15.0-simulator; goos=ios ;;
 *) echo 'Use iphoneos arm64, or iphonesimulator arm64/amd64' >&2;exit 1 ;;
esac
if [[ $(uname -s) == Darwin ]]; then
 sdkpath=$(xcrun --sdk "$sdk" --show-sdk-path)
 clang=$(xcrun --sdk "$sdk" --find clang)
 extra=''
else
 [[ $sdk == iphoneos ]] || { echo 'WSL verification supports device arm64 only' >&2;exit 1; }
 bundle="$HOME/.swiftpm/swift-sdks/darwin.artifactbundle"
 sdkpath=$(find -L "$bundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs" -maxdepth 1 -type d -name 'iPhoneOS*.*.sdk' | sort -V | tail -1)
 clang=/usr/lib/swift/usr/bin/clang
 extra="-fuse-ld=$bundle/toolset/bin/ld64.lld -mlinker-version=907"
fi
[[ -d $sdkpath && -x $clang ]] || { echo 'Apple SDK/clang missing' >&2;exit 1; }
mkdir -p "build/$sdk"
export GOOS=$goos GOARCH=$arch CGO_ENABLED=1
export CC="\"$clang\" -target $target -isysroot \"$sdkpath\""
export CGO_CFLAGS="-target $target -isysroot \"$sdkpath\""
export CGO_LDFLAGS="$CGO_CFLAGS $extra"
go build -mod=readonly -buildmode=c-archive -trimpath -o "build/$sdk/libMoonlightTailscale.a" .
