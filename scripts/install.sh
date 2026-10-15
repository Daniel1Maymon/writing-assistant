#!/bin/bash
# Build the debug app with Xcode, sign it, install it in /Applications and launch it.
# Usage: scripts/install.sh [--probe]
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # no sudo xcode-select needed

APP=WritingAssistant
DEST=/Applications/$APP.app
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/WritingAssistant-local"  # outside Desktop: its file metadata breaks codesign
IDENTITY="WritingAssistant Local Signing"  # decision 0003

xcodegen generate --quiet
xcodebuild -project $APP.xcodeproj -scheme $APP -configuration Debug \
    -derivedDataPath "$DERIVED" -quiet build

BUILT="$DERIVED/Build/Products/Debug/$APP.app"

# Tier 1 helper (decision 0005): copy Homebrew's harper-ls into the bundle so it's signed with the app.
HARPER="$(command -v harper-ls || true)"
if [ -n "$HARPER" ]; then
    mkdir -p "$BUILT/Contents/Helpers"
    cp -fL "$HARPER" "$BUILT/Contents/Helpers/harper-ls"
else
    echo "warning: harper-ls not found (brew install harper); tier 1 falls back to macOS spelling" >&2
fi
HELPER="$BUILT/Contents/Helpers/harper-ls"

# A stable signature is what keeps the Accessibility permission across rebuilds.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    SIGN=("$IDENTITY")
else
    echo "warning: '$IDENTITY' not in keychain; signing ad hoc (permission resets on every rebuild)" >&2
    SIGN=(-)
fi
# Nested code first, then the app that seals it.
[ -f "$HELPER" ] && codesign --force --options runtime --timestamp=none --sign "${SIGN[@]}" "$HELPER"
codesign --force --options runtime --timestamp=none --sign "${SIGN[@]}" "$BUILT"

pkill -x $APP 2>/dev/null || true
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
open "$DEST" --args "$@"
echo "Installed and launched $DEST"
