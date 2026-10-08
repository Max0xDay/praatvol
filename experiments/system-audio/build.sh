#!/bin/bash
set -euo pipefail

scriptDirectory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
applicationPath="$scriptDirectory/praatvol.app"

swiftc -target arm64-apple-macosx14.2 -warnings-as-errors \
    "$scriptDirectory/tap.swift" -o "$scriptDirectory/tap"
mkdir -p "$applicationPath/Contents/MacOS"
cp "$scriptDirectory/Info.plist" "$applicationPath/Contents/Info.plist"
cp "$scriptDirectory/tap" "$applicationPath/Contents/MacOS/tap"
codesign --force --sign - "$applicationPath"
printf 'Built %s\n' "$applicationPath"
