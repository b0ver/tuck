#!/bin/bash
# Packages dist/Tuck.app into dist/Tuck-<version>.dmg with an /Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tuck"
DIST="dist"
APP="$DIST/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/$APP_NAME-$VERSION.dmg"

[ -d "$APP" ] || { echo "Build the app first: Scripts/build-app.sh"; exit 1; }

echo "==> Staging…"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG…"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"

echo "==> Done: $DMG"
