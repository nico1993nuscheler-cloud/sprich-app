#!/usr/bin/env bash
# Build + run Sprich signed with your Developer ID cert — the SAME identity
# as the released app, so it satisfies the keychain ACL and you get NO
# "wants to use confidential information" prompts while testing.
#
# Use this INSTEAD of Xcode ⌘R. Xcode always re-signs Debug builds with
# "Apple Development" (a different cert), which is what triggers the prompt
# cascade every launch. This script keeps the fast Debug config (incremental
# compiles) but signs Developer ID.
#
# Usage:  ./dev-run.sh
set -euo pipefail

cd "$(dirname "$0")"
DERIVED=/tmp/sprich-dev
APP="$DERIVED/Build/Products/Debug/Sprich.app"

echo "▸ Building (Debug, Developer ID signed, incremental)…"
xcodebuild -project Sprich.xcodeproj -scheme Sprich -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application: Nico Nuscheler (AQVX35VD3G)" \
  DEVELOPMENT_TEAM=AQVX35VD3G \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build 2>&1 | grep -iE "error:|warning: .*unused|BUILD SUCCEEDED|BUILD FAILED" || true

if [ ! -d "$APP" ]; then echo "✗ Build product missing — see errors above"; exit 1; fi

echo "▸ Relaunching…"
osascript -e 'tell application "Sprich" to quit' 2>/dev/null || true
pkill -x Sprich 2>/dev/null || true
sleep 1
open "$APP"
echo "✓ Running Developer ID-signed Sprich  ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"
echo "  No keychain prompts — same cert as your release."
