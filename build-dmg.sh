#!/bin/bash
# Sprich — Build a distributable DMG
# Run after install.sh or a manual Release build.
# Output: dist/Sprich-<version>.dmg

set -e

VERSION="${1:-1.0.0}"
APP_NAME="Sprich"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DIST_DIR="dist"

# Build first
echo "[1/4] Building ${APP_NAME} (Release)..."
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" -configuration Release build \
    CONFIGURATION_BUILD_DIR="$(pwd)/build" \
    -quiet

# Stage the DMG contents in a temp dir (the .app + symlink to /Applications).
echo "[2/4] Staging DMG contents..."
DMG_STAGE=$(mktemp -d)
cp -R "build/${APP_NAME}.app" "${DMG_STAGE}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE}/Applications"

# Create the compressed DMG.
echo "[3/4] Creating ${DMG_NAME}..."
mkdir -p "${DIST_DIR}"
rm -f "${DIST_DIR}/${DMG_NAME}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov -format UDZO \
    "${DIST_DIR}/${DMG_NAME}" > /dev/null

echo "[4/4] Cleaning up..."
rm -rf "${DMG_STAGE}"
rm -rf build

echo ""
echo "  =========================================="
echo "  DMG ready: ${DIST_DIR}/${DMG_NAME}"
echo "  Size: $(du -h "${DIST_DIR}/${DMG_NAME}" | cut -f1)"
echo "  =========================================="
echo ""
