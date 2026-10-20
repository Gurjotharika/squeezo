#!/bin/bash
# Turns a notarized Squeezo.app (exported from Xcode: Organizer > Distribute App > Direct Distribution)
# into a DMG and an update feed, and optionally publishes them.
#
#   Scripts/package-direct.sh <path/to/Squeezo.app> [--publish]
#
# The version and build number are read from the app itself.
set -euo pipefail

APP="${1:?usage: package-direct.sh <path/to/Squeezo.app> [--publish]}"
PUBLISH=0; [[ "${2:-}" == "--publish" ]] && PUBLISH=1

RELEASES_REPO="${RELEASES_REPO:-Gurjotharika/squeezo-releases}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_BIN="$ROOT/.tools/sparkle/bin"
APP_NAME="Squeezo"

xcrun stapler validate "$APP" >/dev/null || { echo "The app isn't notarized and stapled."; exit 1; }
VERSION="$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleShortVersionString)"
BUILD="$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleVersion)"
OUT="$ROOT/build/direct/$VERSION"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

rm -rf "$OUT"; mkdir -p "$OUT/dmg"
echo "==> Building the DMG for $VERSION ($BUILD)"
cp -R "$APP" "$OUT/dmg/$APP_NAME.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/dmg"

echo "==> Signing the update for Sparkle"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG")"   # prints: sparkle:edSignature="..." length="..."
URL="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/$(basename "$DMG")"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/x-apple-diskimage" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
cp "$DMG" "$OUT/$APP_NAME.dmg"   # a download link that never changes: .../releases/latest/download/Squeezo.dmg

if [[ $PUBLISH == 1 ]]; then
  echo "==> Publishing to $RELEASES_REPO"
  gh release create "v$VERSION" "$DMG" "$OUT/$APP_NAME.dmg" "$OUT/appcast.xml" \
    --repo "$RELEASES_REPO" --title "$APP_NAME $VERSION" --notes "${RELEASE_NOTES:-$APP_NAME $VERSION}"
fi
echo "Done: $OUT"
