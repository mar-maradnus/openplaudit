#!/bin/bash
# Build OpenPlaudit and wrap it in a .app bundle so macOS treats it as a GUI app.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/.build/OpenPlaudit.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

echo "Building OpenPlaudit..."
cd "$PROJECT_DIR"
swift build 2>&1

echo "Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS"

# Copy binary
cp .build/debug/OpenPlaudit "$MACOS/OpenPlaudit"

# Copy Info.plist
cp Sources/OpenPlaudit/Resources/Info.plist "$CONTENTS/Info.plist"

# Ad-hoc codesign with BLE entitlement
ENTITLEMENTS="$PROJECT_DIR/Sources/OpenPlaudit/Resources/OpenPlaudit.entitlements"
echo "Codesigning with entitlements..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$MACOS/OpenPlaudit"

echo "Launching OpenPlaudit.app..."
open "$APP_DIR"
