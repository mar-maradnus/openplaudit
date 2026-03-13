#!/bin/bash
# Build a release .app bundle and zip it for GitHub Releases.
#
# Produces: .build/release/OpenPlaudit.app.zip
#
# The binary is release-optimised and ad-hoc codesigned with BLE entitlement.
# Not notarised — users must right-click → Open on first launch.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$PROJECT_DIR/.build/release"
APP_DIR="$RELEASE_DIR/OpenPlaudit.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
ENTITLEMENTS="$PROJECT_DIR/Sources/OpenPlaudit/Resources/OpenPlaudit.entitlements"

echo "Building release binary..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

echo "Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS"

cp "$RELEASE_DIR/OpenPlaudit" "$MACOS/OpenPlaudit"
cp Sources/OpenPlaudit/Resources/Info.plist "$CONTENTS/Info.plist"

echo "Codesigning with entitlements..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$MACOS/OpenPlaudit"

echo "Creating zip..."
cd "$RELEASE_DIR"
zip -r OpenPlaudit.app.zip OpenPlaudit.app

SIZE=$(du -sh OpenPlaudit.app.zip | cut -f1)
echo ""
echo "Done: $RELEASE_DIR/OpenPlaudit.app.zip ($SIZE)"
echo "Upload with: gh release create v0.2.0 $RELEASE_DIR/OpenPlaudit.app.zip"
