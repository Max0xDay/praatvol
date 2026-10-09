#!/bin/bash
set -euo pipefail

scriptDirectory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
applicationDirectory="$(cd -- "$scriptDirectory/.." && pwd)"
variant="${1:-}"
case "$variant" in
    dev) applicationName="praatvol Dev"; bundleIdentifier="com.praatvol.app.dev" ;;
    release) applicationName="praatvol"; bundleIdentifier="com.praatvol.app" ;;
    *) printf 'Usage: %s dev|release\n' "$0" >&2; exit 1 ;;
esac
version="$(tr -d '\n\r' < "$applicationDirectory/VERSION")"
cd "$applicationDirectory"
swift build -c release --arch arm64 -Xswiftc -warnings-as-errors
binaryDirectory="$(swift build -c release --arch arm64 --show-bin-path)"
applicationPath="$applicationDirectory/dist/$applicationName.app"
mkdir -p "$applicationPath/Contents/MacOS" "$applicationPath/Contents/Resources"
cp "$binaryDirectory/Praatvol" "$applicationPath/Contents/MacOS/Praatvol"
cp "$applicationDirectory/Info.plist" "$applicationPath/Contents/Info.plist"
plist="$applicationPath/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundleIdentifier" "$plist"
plutil -replace CFBundleName -string "$applicationName" "$plist"
plutil -replace CFBundleDisplayName -string "$applicationName" "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
iconDirectory="$applicationDirectory/.build/icons-$variant"
iconset="$iconDirectory/AppIcon.iconset"
mkdir -p "$iconset"
swift "$scriptDirectory/icon.swift" "$iconDirectory/logo.png" "$variant"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$iconDirectory/logo.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubledSize=$((size * 2))
    sips -z "$doubledSize" "$doubledSize" "$iconDirectory/logo.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$applicationPath/Contents/Resources/AppIcon.icns"
plutil -lint "$plist"
codesign --force --sign - "$applicationPath"
codesign --verify --strict "$applicationPath"
if [[ "$variant" == "release" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$applicationPath" "$applicationDirectory/dist/praatvol-$version.zip"
fi
printf 'Built %s (%s)\n' "$applicationPath" "$bundleIdentifier"
