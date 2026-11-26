#!/bin/bash
# Makes what a Bros release holds, from build/Bros.app, and says how to publish it.
#
#   ./build.sh && ./bros-release.sh "What is new, in a line."
#
# Writes build/Bros.zip (what the app fetches itself), build/Bros.dmg (what a
# person downloads) and build/appcast.json (the feed, signed with the key in
# ~/.config/bros/update.key: keep that file safe and backed up — a Bros that
# is already installed only trusts feeds signed by it).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Bros.app
KEY="${BROS_UPDATE_KEY:-$HOME/.config/bros/update.key}"
NOTES="${1:-}"
[ -d "$APP" ] || { echo "$APP is missing — ./build.sh first" >&2; exit 1; }
[ -f "$KEY" ] || { echo "no signing key at $KEY (swift tools/bros-feed.swift keygen $KEY)" >&2; exit 1; }
codesign --verify --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
TAG="v$VERSION"
BASE="https://github.com/MEPoss/bros/releases/download/$TAG"

# The key in the app is the key that signs.
[ "$(swift tools/bros-feed.swift public "$KEY")" = "$(sed -n 's/.*publicKey = "\(.*\)".*/\1/p' Sources/Search/BrosFeed.swift)" ] \
  || { echo "the key in $KEY is not the one in BrosFeed.swift" >&2; exit 1; }

rm -f build/Bros.zip build/Bros.dmg build/appcast.json
ditto -c -k --keepParent "$APP" build/Bros.zip

# The disk image: the app on the left, Applications on the right, and the
# picture between them (tools/dmg-background.swift). Finder lays it out on a
# writable copy, which is then compressed.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Blocked? Read me.txt" <<'TXT'
If macOS says it "could not verify Bros.app", Bros is not broken: it is signed
by its author, not notarised by Apple.

1. Drag Bros.app to Applications.
2. Open Terminal and paste this line (select it here, copy, paste, Return):

xattr -dr com.apple.quarantine /Applications/Bros.app

3. Open Bros as usual. You do this once; Bros updates itself after that.

Or: System Settings > Privacy & Security > "Open Anyway".
TXT
mkdir "$STAGE/.background"
swift tools/dmg-background.swift "$STAGE/.background/background.png" >/dev/null
RW="$(mktemp -u).dmg"
hdiutil create -quiet -volname Bros -srcfolder "$STAGE" -ov -format UDRW "$RW"
rm -rf "$STAGE"
# A volume of the same name still mounted would take the layout instead.
for OLD in $(hdiutil info | awk '/\/Volumes\/Bros$/{print $1}'); do hdiutil detach -quiet "$OLD" -force || true; done
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEVICE="$(echo "$ATTACH" | awk '/Apple_HFS|APFS/{print $1; exit}')"
osascript <<'OSA' || echo "Finder would not lay the window out: the image is plain" >&2
tell application "Finder"
  tell disk "Bros"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "Bros.app" of container window to {165, 165}
    set position of item "Applications" of container window to {495, 165}
    set position of item "Blocked? Read me.txt" of container window to {330, 322}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
sync
hdiutil detach -quiet "$DEVICE" -force || true
hdiutil convert -quiet "$RW" -format UDZO -o build/Bros.dmg
rm -f "$RW"
# A just-made image may still be attached for a moment.
sleep 3
for DEV in $(hdiutil info | awk '/image-path.*build\/Bros.dmg/{f=1} f&&/^\/dev\/disk[0-9]+\t/{print $1; f=0}'); do
  hdiutil detach -quiet "$DEV" -force || true
done
hdiutil verify -quiet build/Bros.dmg

ZIPSHA="$(shasum -a 256 build/Bros.zip | cut -d' ' -f1)"
DMGSHA="$(shasum -a 256 build/Bros.dmg | cut -d' ' -f1)"
swift tools/bros-feed.swift sign "$KEY" "$VERSION" "$BUILD" "$BASE/Bros.zip" "$ZIPSHA" "$BASE/Bros.dmg" "$DMGSHA" "$NOTES" \
  > build/appcast.json

echo "Bros $VERSION (build $BUILD): build/Bros.zip, build/Bros.dmg, build/appcast.json"
echo "publish: gh release create $TAG build/Bros.dmg build/Bros.zip build/appcast.json --repo MEPoss/bros"
