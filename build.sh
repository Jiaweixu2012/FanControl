#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
APP=FanControl
HELPER=FanControlHelper
BUILD=.build/release
DIST=build/FanControl.app

echo "==> building (release)"
swift build -c release --product $APP
swift build -c release --product $HELPER

echo "==> icons"
mkdir -p build/icons
swift Resources/make_icon.swift "$PWD/build/icons"
iconutil -c icns build/icons/AppIcon.iconset -o build/icons/AppIcon.icns

echo "==> assembling $DIST"
rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS"
mkdir -p "$DIST/Contents/Resources/en.lproj"
mkdir -p "$DIST/Contents/Resources/zh-Hans.lproj"

cp "$BUILD/$APP" "$DIST/Contents/MacOS/$APP"
cp "$BUILD/$HELPER" "$DIST/Contents/Resources/$HELPER"
cp build/icons/AppIcon.icns "$DIST/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$DIST/Contents/Info.plist"
cp Resources/en.lproj/Localizable.strings "$DIST/Contents/Resources/en.lproj/Localizable.strings"
cp Resources/zh-Hans.lproj/Localizable.strings "$DIST/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp install.sh "$DIST/Contents/Resources/install.sh"
chmod +x "$DIST/Contents/Resources/install.sh"

echo "==> codesigning (ad-hoc)"
codesign --force --deep --sign - "$DIST"

echo "==> done: $DIST"
