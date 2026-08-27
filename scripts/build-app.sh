#!/bin/bash
# Builds AudioRecorder.app — a self-contained, double-clickable macOS app.
#
# Usage:
#   scripts/build-app.sh             # build dist/AudioRecorder.app
#   scripts/build-app.sh --install   # build and copy to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AudioRecorder"
BUNDLE_ID="dev.cmatskas.AudioRecorder"
VERSION="1.0.0"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release --product "$APP_NAME"
BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Audio Recorder</string>
    <key>CFBundleDisplayName</key>
    <string>Audio Recorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Audio Recorder captures your selected microphone while recording.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Audio Recorder captures system audio so recordings include what your Mac plays.</string>
</dict>
</plist>
PLIST

echo "==> Code signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"

echo "==> Done: $APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_DIR" "/Applications/$APP_NAME.app"
    echo "==> Installed: /Applications/$APP_NAME.app"
fi
