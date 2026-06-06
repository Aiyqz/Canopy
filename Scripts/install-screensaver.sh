#!/bin/bash
# Builds the CanopyScreenSaver.saver bundle and installs it for the current user.
#
#     ./Scripts/install-screensaver.sh
#
# Then: System Settings → Screen Saver → pick "Canopy", and enable
# "Show on Screen Saver" from the Canopy menu-bar leaf.
#
# IMPORTANT: for the saver to actually display your now-playing card (rather than
# the placeholder), the app AND this saver must be signed with the SAME Apple
# Team ID and share the App Group "group.pro.getcanopy.shared" — that's the only
# directory the sandboxed screen saver can read. Set DEVELOPMENT_TEAM below or in
# the Xcode project. Ad-hoc/unsigned builds fall back to the placeholder.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found (brew install xcodegen)." >&2; exit 1
fi

echo "▸ Generating project…"
xcodegen generate >/dev/null

echo "▸ Building CanopyScreenSaver (Release)…"
DD="build/dd"
xcodebuild -scheme CanopyScreenSaver -configuration Release \
  -derivedDataPath "$DD" \
  ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM} \
  build >/dev/null

SAVER="$DD/Build/Products/Release/CanopyScreenSaver.saver"
if [ ! -d "$SAVER" ]; then
  echo "error: build produced no .saver at $SAVER" >&2; exit 1
fi

DEST="$HOME/Library/Screen Savers"
mkdir -p "$DEST"
rm -rf "$DEST/CanopyScreenSaver.saver"
cp -R "$SAVER" "$DEST/"
echo "✓ Installed to $DEST/CanopyScreenSaver.saver"
echo
echo "Next: open Screen Saver settings and select Canopy."
open "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension" 2>/dev/null || true
