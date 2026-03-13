#!/bin/bash
# Build OpenPlaudit and wrap it in a .app bundle so macOS treats it as a GUI app.
# Uses /tmp to avoid com.apple.provenance xattr issues with codesign on macOS 15+.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/tmp/OpenPlaudit.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

echo "Building OpenPlaudit..."
cd "$PROJECT_DIR"
/usr/bin/swift build 2>&1

# Kill any running instance
pkill -f "OpenPlaudit.app" 2>/dev/null && sleep 1 || true

echo "Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS"

# Copy binary (cat avoids cp's xattr propagation)
cat .build/debug/OpenPlaudit > "$MACOS/OpenPlaudit"
chmod +x "$MACOS/OpenPlaudit"

# Copy Info.plist
cp Sources/OpenPlaudit/Resources/Info.plist "$CONTENTS/Info.plist"

# Ad-hoc codesign with entitlements (BLE + mic)
ENTITLEMENTS="$PROJECT_DIR/Sources/OpenPlaudit/Resources/OpenPlaudit.entitlements"
echo "Codesigning with entitlements..."
codesign --force --sign "Developer ID Application: Ram Sundaram (4Z5DVBGQ95)" --entitlements "$ENTITLEMENTS" "$MACOS/OpenPlaudit"

echo "Launching OpenPlaudit.app..."
open "$APP_DIR"
