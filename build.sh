#!/bin/bash
# Builds Canopy and assembles a runnable .app bundle (ad-hoc signed) with icon.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Canopy"
APP="Canopy.app"

echo "▸ Generating app icon…"
ICON_PNG="/tmp/canopy_icon_master.png"
"$BIN" --icon "$ICON_PNG" >/dev/null 2>&1 || true
if [ -f "$ICON_PNG" ]; then
  ICONSET="/tmp/Canopy.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512 1024; do
    sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    half=$((s/2))
    if [ $s -ge 32 ]; then
      sips -z $half $half "$ICON_PNG" --out "$ICONSET/icon_${half}x${half}@2x.png" >/dev/null 2>&1
    fi
  done
  iconutil -c icns "$ICONSET" -o "/tmp/Canopy.icns" >/dev/null 2>&1 || true
fi

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Canopy"
cp Info.plist "$APP/Contents/Info.plist"
[ -f "/tmp/Canopy.icns" ] && cp "/tmp/Canopy.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the MediaRemote adapter (built by Scripts/fetch-adapter.sh) so the
# swift-build app behaves like the xcodebuild one. Copied, never linked.
[ -f Resources/mediaremote-adapter.pl ] && cp Resources/mediaremote-adapter.pl "$APP/Contents/Resources/"
[ -d Resources/MediaRemoteAdapter.framework ] && cp -R Resources/MediaRemoteAdapter.framework "$APP/Contents/Resources/"
[ -f Resources/MediaRemoteAdapterTestClient ] && cp Resources/MediaRemoteAdapterTestClient "$APP/Contents/Resources/"

echo "▸ Ad-hoc signing (hardened runtime + entitlements)…"
codesign --force --deep --options runtime \
  --entitlements Canopy.entitlements --sign - "$APP" >/dev/null 2>&1 \
  || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
