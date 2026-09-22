#!/bin/bash
# Build build/Joseon.app from the SwiftPM release binary and sign it.
# Usage: scripts/bundle.sh [--install]   (--install copies to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Joseon
APP=build/Joseon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Joseon "$APP/Contents/MacOS/Joseon"
cp scripts/Info.plist "$APP/Contents/Info.plist"
[ -f scripts/AppIcon.icns ] && cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable signature keeps the audio-capture permission across rebuilds.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --entitlements scripts/Joseon.entitlements "$APP"
else
  echo "No Apple Development identity found: ad-hoc signing (permission prompt repeats after each rebuild)" >&2
  codesign --force --sign - --entitlements scripts/Joseon.entitlements "$APP"
fi
codesign --verify --verbose=2 "$APP"
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Joseon.app && cp -R "$APP" /Applications/Joseon.app && echo "Installed /Applications/Joseon.app"
fi
