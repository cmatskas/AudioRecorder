#!/bin/bash
# Builds AudioRecorder.app — a self-contained, double-clickable macOS app.
#
# Usage:
#   scripts/build-app.sh             # build dist/AudioRecorder.app
#   scripts/build-app.sh --install   # build and copy to /Applications
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "Error: do not run this script with sudo." >&2
    echo "It creates root-owned files in dist/ and /Applications that later" >&2
    echo "builds cannot replace. /Applications is admin-writable; sudo is not needed." >&2
    exit 1
fi

cd "$(dirname "$0")/.."

APP_NAME="AudioRecorder"
BUNDLE_ID="dev.cmatskas.AudioRecorder"
# Stamped from the release tag in CI; defaults for local builds.
VERSION="${APP_VERSION:-1.0.0}"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release --product "$APP_NAME"
BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ -f "Assets/AppIcon.icns" ]]; then
    cp "Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

echo "==> Code signing"
# Prefer a Developer ID Application identity (set SIGN_IDENTITY to override,
# or SIGN_IDENTITY=- to force ad-hoc). Developer ID signing enables the
# hardened runtime, which notarization requires.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
fi
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    echo "    identity: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --entitlements scripts/entitlements.plist \
        --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
    echo "    identity: ad-hoc (downloaders must right-click > Open)"
    codesign --force --entitlements scripts/entitlements.plist \
        --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

echo "==> Done: $APP_DIR"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_DIR" "/Applications/$APP_NAME.app"
    echo "==> Installed: /Applications/$APP_NAME.app"
fi
