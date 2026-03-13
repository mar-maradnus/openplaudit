#!/bin/bash
# Build a release .app bundle, sign, notarise, and zip for GitHub Releases.
#
# Produces: OpenPlaudit.app.zip in the project root.
#
# Uses /tmp to avoid com.apple.provenance xattr issues with codesign on macOS 15+.
# Signed with Developer ID Application certificate and notarised by Apple.
#
# Requires: APPLE_ID and APP_PASSWORD environment variables for notarisation.
# Generate an app-specific password at https://appleid.apple.com/account/manage
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/tmp/OpenPlaudit-release.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
ENTITLEMENTS="$PROJECT_DIR/Sources/OpenPlaudit/Resources/OpenPlaudit.entitlements"
TEAM_ID="4Z5DVBGQ95"
IDENTITY="Developer ID Application: Ram Sundaram ($TEAM_ID)"

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
codesign --force --options runtime --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$MACOS/OpenPlaudit"

echo "Creating zip..."
ZIP_PATH="$PROJECT_DIR/OpenPlaudit.app.zip"
cd /tmp
zip -r "$ZIP_PATH" "$(basename "$APP_DIR")"

# Notarise if credentials are available
if [[ -n "${APPLE_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
    echo "Submitting for notarisation..."
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    echo "Stapling notarisation ticket..."
    xcrun stapler staple "$APP_DIR"

    # Re-zip with stapled ticket
    rm "$ZIP_PATH"
    zip -r "$ZIP_PATH" "$(basename "$APP_DIR")"
    echo "Notarisation complete."
else
    echo ""
    echo "Skipping notarisation (set APPLE_ID and APP_PASSWORD to enable)."
    echo "To notarise manually:"
    echo "  xcrun notarytool submit $ZIP_PATH --apple-id YOU@EMAIL --team-id $TEAM_ID --password APP_SPECIFIC_PASSWORD --wait"
    echo "  xcrun stapler staple $APP_DIR"
fi

SIZE=$(du -sh "$ZIP_PATH" | cut -f1)
echo ""
echo "Done: $ZIP_PATH ($SIZE)"
echo "Upload with: gh release create v0.4.1 $ZIP_PATH"
