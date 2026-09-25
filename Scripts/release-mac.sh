#!/bin/bash
# Builds, signs, and notarizes a Developer ID release of the Mac app, then
# regenerates appcast.xml for Sparkle. Run from anywhere; paths below are
# relative to the repo root.
#
# One-time setup (see CLAUDE.md "Sparkle updates" section for the full
# walkthrough):
#   - A "Developer ID Application" certificate for team 9MAKNY2JX8 in
#     Keychain (Xcode > Settings > Accounts > Manage Certificates > +).
#   - Notarization credentials stored once:
#       xcrun notarytool store-credentials ftx1remote-notary \
#         --apple-id you@example.com --team-id 9MAKNY2JX8 \
#         --password <app-specific password from appleid.apple.com>
#   - Sparkle's `generate_appcast` and `sign_update` on PATH — either
#     `brew install sparkle`, or unzip the Sparkle release distribution
#     from https://github.com/sparkle-project/Sparkle/releases and add
#     its bin/ dir to PATH.
#   - The Sparkle EdDSA signing key already generated (`generate_keys`,
#     run once ever) and present in this Mac's Keychain — `generate_appcast`
#     finds and uses it automatically, no key material touches this script.
#
# Usage: Scripts/release-mac.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="FTX1RemoteMac"
PROJECT="FTX1RemoteMac/FTX1RemoteMac.xcodeproj"
BUILD_DIR="build"
ARCHIVE_DIR="$BUILD_DIR/archives"
EXPORT_DIR="$BUILD_DIR/export"
RELEASES_DIR="releases"
NOTARY_PROFILE="ftx1remote-notary"
GITHUB_REPO="captobie/ftx1-remote"

mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR" "$RELEASES_DIR"

VERSION=$(xcodebuild -project "$PROJECT" -target "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
if [ -z "$VERSION" ]; then
  echo "error: couldn't read MARKETING_VERSION from $PROJECT" >&2
  exit 1
fi
ARCHIVE_PATH="$ARCHIVE_DIR/$SCHEME-$VERSION.xcarchive"

echo "==> Archiving $SCHEME $VERSION"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS'

echo "==> Exporting Developer ID-signed app"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist Scripts/ExportOptions.plist

APP_PATH="$EXPORT_DIR/$SCHEME.app"
ZIP_PATH="$RELEASES_DIR/$SCHEME-$VERSION.zip"

echo "==> Zipping for notarization submission"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting for notarization (can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket to the app"
xcrun stapler staple "$APP_PATH"

echo "==> Re-zipping stapled app for distribution"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Regenerating appcast.xml"
# Earlier releases' zips stay in $RELEASES_DIR on purpose: generate_appcast
# builds delta updates from them. But it also re-points every archive it
# finds at --download-url-prefix, including old ones (0.5's link was
# rewritten to v0.6/ this way), so start from the committed appcast and
# afterwards put back the original URL of every file it already listed.
# Only files new in this release keep the v$VERSION/ prefix.
cp appcast.xml "$RELEASES_DIR/appcast.xml"
generate_appcast "$RELEASES_DIR" \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/"
grep -o 'url="[^"]*"' appcast.xml | sed -e 's/^url="//' -e 's/"$//' | while read -r url; do
  file="${url##*/}"
  sed -i '' "s#url=\"[^\"]*/${file//./\\.}\"#url=\"$url\"#" "$RELEASES_DIR/appcast.xml"
done
mv "$RELEASES_DIR/appcast.xml" appcast.xml

NEW_FILES=$(grep -o "url=\"[^\"]*/releases/download/v$VERSION/[^\"]*\"" appcast.xml \
  | sed -e 's#.*/##' -e 's/"$//' | sed "s#^#$RELEASES_DIR/#" | tr '\n' ' ' || true)

echo
echo "Done: $ZIP_PATH, appcast.xml updated for v$VERSION."
echo "Enclosure URLs now in appcast.xml:"
grep -o 'url="[^"]*"' appcast.xml | sed 's/^/  /'
echo "Next steps (in this order: the release must exist before the appcast is"
echo "live, or updating clients get a 404):"
echo "  1. gh release create v$VERSION ${NEW_FILES}--title v$VERSION --notes-file $RELEASES_DIR/notes-$VERSION.md"
echo "  2. git add appcast.xml && git commit -m 'Update appcast for v$VERSION' && git push"
