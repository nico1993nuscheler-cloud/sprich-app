#!/bin/bash
# Sprich — Open-Source macOS Speech-to-Text
# One-command installer: builds from source and installs to /Applications

set -e

echo ""
echo "  =========================================="
echo "  Sprich — Speech-to-Text for macOS"
echo "  =========================================="
echo ""

# Check Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: Xcode is not installed."
    echo "Please install Xcode from the App Store (free) and try again."
    echo "https://apps.apple.com/app/xcode/id497799835"
    exit 1
fi

# macOS version check (14+)
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_MAJOR" -lt 14 ]; then
    echo "ERROR: Sprich requires macOS 14 (Sonoma) or later."
    echo "       You're running macOS $(sw_vers -productVersion)."
    exit 1
fi

# Quit any running instance so we can overwrite the .app safely.
if pgrep -f "/Applications/Sprich.app/Contents/MacOS/Sprich" >/dev/null 2>&1; then
    echo "[0/4] Quitting running Sprich instance..."
    osascript -e 'tell application "Sprich" to quit' 2>/dev/null || true
    sleep 1
    pkill -f "/Applications/Sprich.app/Contents/MacOS/Sprich" 2>/dev/null || true
fi

echo "[1/4] Building Sprich (Release configuration)..."
xcodebuild -project Sprich.xcodeproj -scheme Sprich -configuration Release build \
    CONFIGURATION_BUILD_DIR="$(pwd)/build" \
    -quiet

echo "[2/4] Installing to /Applications..."
if [ -d "/Applications/Sprich.app" ]; then
    echo "       Removing previous version..."
    rm -rf "/Applications/Sprich.app"
fi
cp -R "build/Sprich.app" "/Applications/Sprich.app"

echo "[3/4] Cleaning up build artifacts..."
rm -rf build

echo "[4/4] Launching Sprich..."
open "/Applications/Sprich.app"

echo ""
echo "  =========================================="
echo "  Done! Sprich is now running in your menu bar."
echo ""
echo "  Next steps (onboarding will guide you):"
echo "    1. Grant Accessibility permission"
echo "    2. Grant Microphone permission"
echo "    3. Paste your Groq API key (free: console.groq.com/keys)"
echo "    4. Approve the Keychain consent prompt (Always Allow)"
echo ""
echo "  After that: hold fn+shift, speak, release. Done."
echo "  =========================================="
echo ""
