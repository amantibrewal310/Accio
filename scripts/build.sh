#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
# Signing identity: ACCIO_SIGN_IDENTITY, else the local one from
# scripts/dev-signing.sh, else ad-hoc. Any stable identity lets macOS keep
# the Accessibility grant across rebuilds; ad-hoc builds must be re-granted.
DEV_KEYCHAIN="$HOME/Library/Keychains/accio-dev.keychain-db"
SIGN_IDENTITY="${ACCIO_SIGN_IDENTITY:--}"
SIGN_ARGS=()
if [ -z "$ACCIO_SIGN_IDENTITY" ] && [ -f "$DEV_KEYCHAIN" ]; then
    security unlock-keychain -p accio-dev "$DEV_KEYCHAIN"
    SIGN_IDENTITY="Accio Local Development"
    SIGN_ARGS=(--keychain "$DEV_KEYCHAIN")
fi

echo "🍏 Step 1/2: Building Swift App (Accio)..."
cd "$PROJECT_ROOT/app"
swift build -c release

echo "📦 Step 2/2: Assembling macOS App Bundle (Accio.app)..."
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/Accio.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Start from a clean bundle so no stale files end up in a release
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$PROJECT_ROOT/app/.build/release/Accio" "$MACOS_DIR/Accio"
strip "$MACOS_DIR/Accio"

cat << PLIST > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Accio</string>
    <key>CFBundleIdentifier</key>
    <string>com.accio.app</string>
    <key>CFBundleName</key>
    <string>Accio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

echo "✨ Build succeeded! App bundle created and signed at:"
echo "   $APP_BUNDLE"
