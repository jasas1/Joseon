#!/bin/bash
# Makes build/Joseon-v<version>-macos.zip, the file the updater of the app fetches.
# The version is CFBundleShortVersionString in scripts/Info.plist: raise it first.
# Usage: scripts/release.sh            build, sign, zip, print the checksum
#        scripts/release.sh --notarize also send the zip to Apple (needs a Developer ID identity and a
#                                      notarytool keychain profile named "joseon")
# Publishing is a separate step on purpose: the script prints the command and does not run it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
ZIP="build/Joseon-v$VERSION-macos.zip"
scripts/bundle.sh
APP=build/Joseon.app
# A Developer ID signature (with the hardened runtime) is what other Macs accept. Without one the
# bundle keeps the signature of bundle.sh: fine for the Macs of the developer, refused elsewhere.
DEVELOPER_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" --entitlements scripts/Joseon.entitlements "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "No Developer ID identity: this zip opens only on Macs that trust the development certificate." >&2
fi
# ditto writes the zip anew when one is there already.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
if [ "${1:-}" = "--notarize" ]; then
  [ -n "$DEVELOPER_ID" ] || { echo "Notarization needs a Developer ID identity" >&2; exit 1; }
  xcrun notarytool submit "$ZIP" --keychain-profile joseon --wait
  xcrun stapler staple "$APP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
fi
echo "Made $ZIP"
shasum -a 256 "$ZIP"
echo "To publish (after approval):"
echo "  gh release create v$VERSION $ZIP --repo jasas1/Joseon --title \"Joseon $VERSION\" --notes \"...\""
