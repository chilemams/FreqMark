#!/bin/bash
# Builds FreqMark.dmg: Release app + /Applications symlink, dragged-install layout.
set -euo pipefail

cd ~/FreqMark

# 1. Release build
xcodebuild -project FreqMark.xcodeproj -scheme FreqMark -configuration Release build 2>&1 | grep -E "error:|BUILD" | tail -1
APP=$(find ~/Library/Developer/Xcode/DerivedData/FreqMark-*/Build/Products/Release -name "FreqMark.app" -maxdepth 2 | head -1)
[ -d "$APP" ] || { echo "app not built"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DIR=/tmp/freqmark-dmg-staging
DMG=~/FreqMark/dist/FreqMark-${VERSION}.dmg
mkdir -p dist
rm -rf "$DIR" "$DMG" /tmp/freqmark-unsigned.dmg
mkdir -p "$DIR"

# 2. Stage: app + Applications symlink (classic drag-to-install)
cp -R "$APP" "$DIR/"
ln -s /Applications "$DIR/Applications"

# 3. Create the DMG (UDZO compressed)
hdiutil create -volname "FreqMark ${VERSION}" \
  -srcfolder "$DIR" \
  -ov -format UDZO \
  "$DMG"

# 4. Verify it mounts and contains both items
MNT=$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)
[ -d "$MNT/FreqMark.app" ] && [ -L "$MNT/Applications" ] && echo "DMG verified: app + Applications symlink OK" || { echo "DMG verification FAILED"; hdiutil detach "$MNT"; exit 1; }
hdiutil detach "$MNT" >/dev/null

ls -lh "$DMG"
echo "DONE: $DMG"
