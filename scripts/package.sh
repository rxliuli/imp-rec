#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(plutil -extract CFBundleShortVersionString raw imp-rec/Info.plist)
APP_NAME="ImpRec"
DMG_NAME="ImpRec-${VERSION}.dmg"
BUILD_DIR="build/Release"
APP_BUNDLE="${BUILD_DIR}/ImpRec.app"

# Find Developer ID certificate
if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    if [ -z "$SIGN_ID" ]; then
        echo "Error: No Developer ID Application certificate found"
        exit 1
    fi
fi
echo "Signing with: $SIGN_ID"

# 1. Build Release
echo "Building..."
xcodebuild -project imp-rec.xcodeproj \
    -scheme imp-rec \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    CONFIGURATION_BUILD_DIR="$(pwd)/${BUILD_DIR}" \
    CODE_SIGN_IDENTITY="${SIGN_ID}" \
    DEVELOPMENT_TEAM=N2X78TUUFG \
    clean build

# 2. Sign with timestamp (required for notarization)
echo "Signing..."
codesign --force --sign "$SIGN_ID" \
    --options runtime \
    --timestamp \
    --entitlements imp-rec/imp-rec.entitlements \
    "$APP_BUNDLE"

# 3. Verify
echo "Verifying..."
codesign --verify --deep --strict "$APP_BUNDLE"

# 4. Create DMG
echo "Creating DMG..."
rm -f "$DMG_NAME"

if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 100 \
        --icon "ImpRec.app" 180 170 \
        --hide-extension "ImpRec.app" \
        --app-drop-link 480 170 \
        --codesign "$SIGN_ID" \
        "$DMG_NAME" \
        "$APP_BUNDLE"
else
    STAGING=$(mktemp -d)
    cp -R "$APP_BUNDLE" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_NAME"
    rm -rf "$STAGING"
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG_NAME"
fi

# 5. Notarize
echo "Notarizing..."
xcrun notarytool submit "$DMG_NAME" \
    --keychain-profile "notarytool" \
    --wait

# 6. Staple
echo "Stapling..."
xcrun stapler staple "$DMG_NAME"

echo ""
echo "Done: $DMG_NAME ($VERSION)"
ls -lh "$DMG_NAME"
