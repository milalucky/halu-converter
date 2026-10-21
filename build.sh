#!/bin/bash
# Builds "build/Halu Converter.app". Usage: ./build.sh   (add --install to copy it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Halu Converter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HaluConverter "$APP/Contents/MacOS/HaluConverter"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    swift Scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Halu Converter.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Halu Converter.app"
fi
