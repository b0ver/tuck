#!/bin/bash
# Builds Tuck.app into dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tuck"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building (release)…"
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN_PATH=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
    echo "    universal binary (arm64 + x86_64)"
else
    echo "    universal build unavailable, falling back to native arch"
    swift build -c release
    BIN_PATH=$(swift build -c release --show-bin-path)
fi

echo "==> Generating app icon…"
mkdir -p Build
if [ ! -f Build/AppIcon.icns ]; then
    rm -rf Build/AppIcon.iconset
    swift Scripts/MakeIcon.swift Build/AppIcon.iconset
    iconutil -c icns Build/AppIcon.iconset -o Build/AppIcon.icns
fi

echo "==> Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SPM resource bundle (localizations etc.)
if [ -d "$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -R "$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle" "$APP/Contents/Resources/"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
