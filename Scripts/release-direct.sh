#!/bin/bash
# Builds, signs, notarizes and publishes the website edition (license keys + Sparkle updates).
#
#   Scripts/release-direct.sh <version> <build> [--no-publish]
#   Scripts/release-direct.sh 1.0.1 2
#
# One-time setup is in RELEASE-DIRECT.md. The build number must go up with every release.
set -euo pipefail

VERSION="${1:?usage: release-direct.sh <version> <build> [--no-publish]}"
BUILD="${2:?usage: release-direct.sh <version> <build> [--no-publish]}"
PUBLISH=1; [[ "${3:-}" == "--no-publish" ]] && PUBLISH=0

RELEASES_REPO="${RELEASES_REPO:-Gurjotharika/squeezo-releases}"
NOTARY_PROFILE="${NOTARY_PROFILE:-squeezo-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/direct/$VERSION"
SPARKLE_BIN="$ROOT/.tools/sparkle/bin"
APP_NAME="Squeezo"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

rm -rf "$OUT"; mkdir -p "$OUT"
cd "$ROOT"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || { echo "Notarization login '$NOTARY_PROFILE' not set up: see RELEASE-DIRECT.md"; exit 1; }

echo "==> Archiving $VERSION ($BUILD)"
xcodebuild -project Compress.xcodeproj -scheme CompressDirect -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/direct.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates archive | tail -3

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/direct.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist Scripts/ExportOptions-Direct.plist -allowProvisioningUpdates | tail -3
APP="$OUT/export/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
xcrun notarytool submit "$OUT/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Building the DMG"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
# The app inside is signed, notarized and stapled, which is what Gatekeeper checks. Sparkle signs the DMG itself below.

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
echo "Done: $DMG"
