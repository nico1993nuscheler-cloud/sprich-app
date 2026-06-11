#!/bin/bash
# release-dmg.sh — publish a notarized DMG into the landing site + appcast.
#
# Step 7a/7b of the release pipeline. Run AFTER ./notarize.sh <version>
# produced dist/Sprich-<version>.dmg.
#
# What it does:
#   1. Copies dist/Sprich-<version>.dmg → landing/public/dmg/Sprich-<version>.dmg
#      (versioned URL: each appcast item keeps a permanently valid
#      EdDSA-signature/file pair — never repoint old items at new bytes)
#      and → landing/public/dmg/Sprich-latest.dmg (website download button).
#   2. Signs the DMG with the Sparkle EdDSA key (key lives in the macOS
#      keychain; sign_update reads it from there).
#   3. Prints the ready-to-paste appcast <item> block with the versioned URL.
#
# It does NOT edit appcast.xml — paste the printed block as the FIRST <item>
# and prune items older than the oldest versioned DMG you keep in public/dmg/.
#
# Usage:
#   ./scripts/release-dmg.sh 1.0.16 15
#                            ^version ^build number (CFBundleVersion / sparkle:version)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release-dmg.sh <version> <build>}"
BUILD="${2:?usage: release-dmg.sh <version> <build>}"

SRC="${REPO_ROOT}/dist/Sprich-${VERSION}.dmg"
DMG_DIR="${REPO_ROOT}/landing/public/dmg"
SIGN_UPDATE="${REPO_ROOT}/.release-dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"

[ -f "${SRC}" ] || { echo "ERROR: ${SRC} not found — run ./notarize.sh ${VERSION} first"; exit 1; }
[ -x "${SIGN_UPDATE}" ] || { echo "ERROR: sign_update not found at ${SIGN_UPDATE} (run a release build to fetch Sparkle artifacts)"; exit 1; }

cp "${SRC}" "${DMG_DIR}/Sprich-${VERSION}.dmg"
cp "${SRC}" "${DMG_DIR}/Sprich-latest.dmg"

LENGTH=$(stat -f%z "${SRC}")
SIGNATURE=$("${SIGN_UPDATE}" -p "${SRC}")

cat <<EOF

Published:
  ${DMG_DIR}/Sprich-${VERSION}.dmg
  ${DMG_DIR}/Sprich-latest.dmg (alias)

Paste this as the first <item> in landing/public/appcast.xml:

        <item>
            <title>Sprich ${VERSION}</title>
            <pubDate>$(date -R)</pubDate>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://sprichapp.com/dmg/Sprich-${VERSION}.dmg"
                sparkle:edSignature="${SIGNATURE}"
                length="${LENGTH}"
                type="application/octet-stream" />
            <description><![CDATA[
                <h3>What's new in ${VERSION}</h3>
                <ul>
                    <li>TODO release notes</li>
                </ul>
            ]]></description>
        </item>
EOF
