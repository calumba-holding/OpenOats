#!/usr/bin/env bash
set -euo pipefail

# Build signed macOS .app for On The Spot v2 (Swift)
# Usage:
#   ./scripts/build_swift_app.sh
#
# For CI / explicit identity:
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_swift_app.sh
#
# For notarization:
#   APPLE_ID="name@example.com"
#   APPLE_TEAM_ID="TEAMID123"
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SWIFT_DIR="$ROOT_DIR/OnTheSpot"
APP_NAME="On The Spot"
BUNDLE_ID="com.onthespot.app"

echo "=== Building $APP_NAME (Swift) ==="

# Build release binary
cd "$SWIFT_DIR"
swift build -c release 2>&1
BINARY_PATH=".build/release/OnTheSpot"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

echo "Binary built: $BINARY_PATH"

# Create .app bundle
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/OnTheSpot"

# Copy Info.plist
cp "$SWIFT_DIR/Sources/OnTheSpot/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy app icon
ICON_PATH="$SWIFT_DIR/Sources/OnTheSpot/Assets/AppIcon.icns"
if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "App icon copied"
fi

# Add PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"

# Auto-detect signing identity if not set
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  fi
fi

# Sign the app
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  ENTITLEMENTS="$SWIFT_DIR/Sources/OnTheSpot/OnTheSpot.entitlements"
  echo "Signing with: $CODESIGN_IDENTITY"

  codesign --force --deep --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_DIR"

  echo "Code signing complete"
  codesign -vvv "$APP_DIR"
else
  echo "Warning: No signing identity found. App will be unsigned."
fi

# Notarize if credentials are available
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "Submitting for notarization..."

  ZIP_PATH="$ROOT_DIR/dist/OnTheSpot-notarize.zip"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

  xcrun stapler staple "$APP_DIR"
  rm -f "$ZIP_PATH"
  echo "Notarization complete"
fi

# Install to /Applications
cp -R "$APP_DIR" /Applications/
echo "Installed to /Applications/$APP_NAME.app"

echo "=== Build complete ==="
