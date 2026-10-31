#!/bin/zsh
# Builds DragConvert.app and packs it into a drag-to-Applications disk image for GitHub Releases.
#
#   scripts/make-dmg.sh   → build/DragConvert-<version>.dmg (and prints its SHA-256 for the Homebrew cask)
#
# Needs Vendor/ffmpeg (scripts/build-ffmpeg.sh). The app is ad-hoc signed, not notarized.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
[[ -x Vendor/ffmpeg/bin/ffmpeg ]] || { print "Vendor/ffmpeg is missing: run scripts/build-ffmpeg.sh first"; exit 1; }

scripts/build-app.sh
APP="$ROOT/build/DragConvert.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# A public binary must not carry the builder's home folder (ffmpeg embeds its configure line, Swift embeds
# source paths in assertions).
if grep -rIlas --binary-files=text "$HOME" "$APP" >/dev/null; then
  print "Refusing to package: $HOME appears inside the app:"
  grep -rIlas --binary-files=text "$HOME" "$APP"
  exit 1
fi

STAGING="$ROOT/build/dmg"
DMG="$ROOT/build/DragConvert-$VERSION.dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "DragConvert" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"

print "Ready: $DMG"
print "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
