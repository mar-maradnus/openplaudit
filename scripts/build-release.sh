#!/bin/bash
# Build a release .app bundle and zip it for GitHub Releases.
#
# Produces: OpenPlaudit.app.zip in the project root.
#
# Uses /tmp to avoid com.apple.provenance xattr issues with codesign on macOS 15+.
# Signed with self-signed "OpenPlaudit Dev" certificate for stable TCC identity.
# Not notarised — users must right-click → Open on first launch.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/tmp/OpenPlaudit-release.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
ENTITLEMENTS="$PROJECT_DIR/Sources/OpenPlaudit/Resources/OpenPlaudit.entitlements"

echo "Building release binary..."
cd "$PROJECT_DIR"
/usr/bin/swift build -c release 2>&1

echo "Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS"

# cat avoids cp's xattr propagation
cat .build/release/OpenPlaudit > "$MACOS/OpenPlaudit"
chmod +x "$MACOS/OpenPlaudit"
cp Sources/OpenPlaudit/Resources/Info.plist "$CONTENTS/Info.plist"

echo "Codesigning with entitlements..."
codesign --force --sign "OpenPlaudit Dev" --entitlements "$ENTITLEMENTS" "$MACOS/OpenPlaudit"

echo "Creating zip..."
cd /tmp
zip -r "$PROJECT_DIR/OpenPlaudit.app.zip" "$(basename "$APP_DIR")"

SIZE=$(du -sh "$PROJECT_DIR/OpenPlaudit.app.zip" | cut -f1)
echo ""
echo "Done: $PROJECT_DIR/OpenPlaudit.app.zip ($SIZE)"
echo "Upload with: gh release create v0.4.0 $PROJECT_DIR/OpenPlaudit.app.zip"
