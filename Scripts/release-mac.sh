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
generate_appcast "$RELEASES_DIR" \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/"
mv "$RELEASES_DIR/appcast.xml" appcast.xml

echo
echo "Done: $ZIP_PATH, appcast.xml updated for v$VERSION."
echo "Next steps:"
echo "  1. git add appcast.xml && git commit -m 'Update appcast for v$VERSION' && git push"
echo "  2. gh release create v$VERSION '$ZIP_PATH' --title v$VERSION --notes '<changelog>'"
