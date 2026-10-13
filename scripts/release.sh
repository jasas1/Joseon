#!/bin/bash
# Makes build/Joseon-v<version>-macos.zip, the file the updater of the app fetches, and
# build/Joseon-v<version>-macos.dmg, the file people download from the project page.
# The version is CFBundleShortVersionString in scripts/Info.plist: raise it first.
# Usage: scripts/release.sh            build, sign, zip, dmg, print the checksums
#        scripts/release.sh --notarize also send both to Apple (needs a Developer ID identity and a
#                                      notarytool keychain profile named "joseon")
#        JOSEON_SIGN_ADHOC=1 scripts/release.sh   a build with no identity in it (see bundle.sh)
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
DMG="build/Joseon-v$VERSION-macos.dmg"
make_zip() { /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"; }   # ditto writes the zip anew
make_dmg() {
  local stage="build/dmg-stage"
  rm -rf "$stage" "$DMG"
  mkdir -p "$stage"
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "Joseon" -srcfolder "$stage" -ov -format UDZO "$DMG"
  rm -rf "$stage"
  [ -n "$DEVELOPER_ID" ] && codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  true
}
make_zip
if [ "${1:-}" = "--notarize" ]; then
  [ -n "$DEVELOPER_ID" ] || { echo "Notarization needs a Developer ID identity" >&2; exit 1; }
  xcrun notarytool submit "$ZIP" --keychain-profile joseon --wait
  xcrun stapler staple "$APP"
  make_zip
  make_dmg
  xcrun notarytool submit "$DMG" --keychain-profile joseon --wait
  xcrun stapler staple "$DMG"
else
  make_dmg
fi
echo "Made $ZIP and $DMG"
shasum -a 256 "$ZIP" "$DMG"
echo "To publish (after approval):"
echo "  gh release create v$VERSION $ZIP $DMG --repo jasas1/Joseon --title \"Joseon $VERSION\" --notes \"...\""
