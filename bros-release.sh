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

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Bros -srcfolder "$STAGE" -ov -format UDZO build/Bros.dmg
rm -rf "$STAGE"
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
