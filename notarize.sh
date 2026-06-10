#!/bin/bash
# Sprich — Build + codesign + notarize + staple a release DMG.
#
# This is the *release* path. For local dev iteration use build-dmg.sh,
# which produces an ad-hoc-signed DMG without the Apple notarization
# round-trip (5–60+ min depending on Apple's queue).
#
# Output: dist/Sprich-<version>.dmg — passes `spctl -a -v --type install`
# as "Notarized Developer ID", launches on a clean Mac without any
# Gatekeeper warning.
#
# Prerequisites (one-time on this Mac):
#
#   1. "Developer ID Application: Nico Nuscheler (AQVX35VD3G)" certificate
#      installed in the login keychain. Easiest path: Xcode → Settings →
#      Accounts → select Apple ID → Manage Certificates → + → Developer ID
#      Application. Verify with:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#
#   2. Notarytool keychain profile named `sprich-notarytool`. Generate an
#      app-specific password at appleid.apple.com (Sign-In and Security →
#      App-Specific Passwords) and store it once with:
#        xcrun notarytool store-credentials sprich-notarytool \
#            --apple-id <your-apple-id-email> \
#            --team-id <your-developer-team-id> \
#            --password <app-specific-password>
#      Once stored, the raw password can be revoked at appleid.apple.com —
#      Apple validates the cached credential token, not the password text.
#
# Usage:
#   ./notarize.sh 1.1.0          # builds the version you pass (required)
#
# After notarization, publish with: ./scripts/release-dmg.sh <version> <build>

set -e

if [ -z "${1:-}" ]; then
    echo "ERROR: version argument required, e.g. ./notarize.sh 1.0.16"
    exit 1
fi
VERSION="$1"
APP_NAME="Sprich"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DIST_DIR="dist"
TEAM_ID="AQVX35VD3G"
SIGN_IDENTITY="Developer ID Application: Nico Nuscheler (${TEAM_ID})"
NOTARY_PROFILE="sprich-notarytool"

# Sanity-check the signing identity is present before touching anything.
# Avoids spending 90 s on xcodebuild only to fail at the codesign step.
if ! security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}"; then
    echo "ERROR: signing identity not found in keychain:"
    echo "  ${SIGN_IDENTITY}"
    echo ""
    echo "Install the 'Developer ID Application' certificate from"
    echo "https://developer.apple.com/account/resources/certificates/list"
    echo "(or via Xcode → Settings → Accounts → Manage Certificates) before"
    echo "running this script."
    exit 1
fi

echo "[1/7] Building ${APP_NAME} (Release)..."
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" -configuration Release build \
    CONFIGURATION_BUILD_DIR="$(pwd)/build" \
    -quiet

# Codesign the .app bundle with hardened runtime + secure timestamp.
# Both are notarization requirements — Apple rejects non-hardened builds
# and any signature without an Apple-anchored timestamp.
echo "[2/7] Codesigning ${APP_NAME}.app..."
codesign --deep --force \
    --options runtime \
    --timestamp \
    --sign "${SIGN_IDENTITY}" \
    "build/${APP_NAME}.app"

# Verify the signature is valid before packaging — catches mis-signed
# embedded frameworks early instead of mid-notarization.
codesign --verify --deep --strict --verbose=2 "build/${APP_NAME}.app"

# Stage the DMG contents in a temp dir (.app + symlink to /Applications).
echo "[3/7] Staging DMG contents..."
DMG_STAGE=$(mktemp -d)
cp -R "build/${APP_NAME}.app" "${DMG_STAGE}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE}/Applications"

echo "[4/7] Creating ${DMG_NAME}..."
mkdir -p "${DIST_DIR}"
rm -f "${DIST_DIR}/${DMG_NAME}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -ov -format UDZO \
    "${DIST_DIR}/${DMG_NAME}" > /dev/null

# Codesign the DMG container itself. Notarization accepts unsigned DMGs,
# but stapling requires a signed container — and a signed DMG also surfaces
# the Developer ID in Finder's Get Info pane.
echo "[5/7] Codesigning ${DMG_NAME}..."
codesign --force \
    --sign "${SIGN_IDENTITY}" \
    --timestamp \
    "${DIST_DIR}/${DMG_NAME}"

# Submit to Apple notarization. --wait blocks until Apple finishes
# (typically 1-5 min, occasionally hours during their queue's bad days).
# Any rejection aborts the script via `set -e`.
echo "[6/7] Submitting to Apple notarization..."
xcrun notarytool submit "${DIST_DIR}/${DMG_NAME}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# Staple the notarization ticket so the DMG passes Gatekeeper OFFLINE.
# Without stapling, Gatekeeper has to phone home to Apple on first launch
# — works on broadband but fails air-gapped.
echo "[7/7] Stapling + verifying..."
xcrun stapler staple "${DIST_DIR}/${DMG_NAME}"
xcrun stapler validate "${DIST_DIR}/${DMG_NAME}"

# Final independent sanity check: does Gatekeeper actually accept this DMG
# as a notarized installer? Must print "accepted ... source=Notarized
# Developer ID" — anything else means the binary must NOT be published.
spctl -a -v --type install "${DIST_DIR}/${DMG_NAME}"

# Clean up
rm -rf "${DMG_STAGE}"
rm -rf build

echo ""
echo "  =========================================="
echo "  DMG ready: ${DIST_DIR}/${DMG_NAME}"
echo "  Size: $(du -h "${DIST_DIR}/${DMG_NAME}" | cut -f1)"
echo "  Signed + notarized + stapled."
echo "  =========================================="
echo ""
