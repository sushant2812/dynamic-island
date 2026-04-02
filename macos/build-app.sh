#!/bin/bash
set -euo pipefail

APP_NAME="Dynamic Island"
BUNDLE_ID="com.sushant.dynamicisland"
EXECUTABLE="macos"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/release"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "▸ Building release binary…"
cd "$SCRIPT_DIR"
swift build -c release --arch arm64 2>&1

echo "▸ Creating app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$EXECUTABLE" "$MACOS_DIR/$EXECUTABLE"

cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Dynamic Island</string>
    <key>CFBundleDisplayName</key>
    <string>Dynamic Island</string>
    <key>CFBundleIdentifier</key>
    <string>com.sushant.dynamicisland</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>macos</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Dynamic Island uses AppleScript to detect and control media playback in Spotify, Apple Music, and Chrome.</string>
</dict>
</plist>
PLIST

SPM_BUNDLE="$BUILD_DIR/${EXECUTABLE}_macos.bundle"
if [ -d "$SPM_BUNDLE" ]; then
    # SPM's resource_bundle_accessor looks for <AppName.app>/macos_macos.bundle (sibling of Contents).
    # Only placing the bundle under Contents/MacOS breaks Bundle.module at runtime.
    cp -R "$SPM_BUNDLE" "$APP_DIR/"
    cp -R "$SPM_BUNDLE" "$MACOS_DIR/"
fi

echo "▸ Done! App bundle created at:"
echo "  $APP_DIR"
echo ""
echo "To install, run:"
echo "  cp -R \"$APP_DIR\" /Applications/"
echo ""
echo "Or just double-click the .app to launch it."
