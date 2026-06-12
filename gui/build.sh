#!/bin/bash
# Build RecoveryKit.app from the single-file AppKit source.
set -e
cd "$(dirname "$0")"
APP="../RecoveryKit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp RecoveryKit.icns "$APP/Contents/Resources/"
# -swift-version 5: avoid Swift 6 strict-concurrency errors in plain AppKit code
# -target: pin the minimum OS to match Info.plist LSMinimumSystemVersion
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos12.0 main.swift -o "$APP/Contents/MacOS/RecoveryKit"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built: $(cd .. && pwd)/RecoveryKit.app"
