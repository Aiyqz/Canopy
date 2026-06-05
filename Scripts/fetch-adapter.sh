#!/bin/bash
# Builds the MediaRemoteAdapter.framework + MediaRemoteAdapterTestClient from
# ungive/mediaremote-adapter and drops them into Resources/ so the Xcode build's
# resources copy phase can bundle them.
#
# Run this ONCE on a Mac before building (needs Xcode Command Line Tools + cmake):
#
#     ./Scripts/fetch-adapter.sh
#
# The reviewable Perl script (Resources/mediaremote-adapter.pl) is committed to
# the repo; only the compiled framework + test client are produced here (and are
# git-ignored). The framework is BUNDLED, never linked or embedded — Canopy only
# passes its path to /usr/bin/perl at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="https://github.com/ungive/mediaremote-adapter.git"
# Pin to the upstream commit whose mediaremote-adapter.pl is vendored here, so
# the script CLI and the built framework stay in lockstep.
REF="${MEDIAREMOTE_ADAPTER_REF:-master}"

BUILD_DIR="Resources/.adapter-build"
DEST="Resources"

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake not found. Install it (e.g. 'brew install cmake') and retry." >&2
  exit 1
fi

echo "▸ Cloning $REPO ($REF)…"
rm -rf "$BUILD_DIR"
git clone --depth 1 --branch "$REF" "$REPO" "$BUILD_DIR" 2>/dev/null \
  || git clone "$REPO" "$BUILD_DIR"

echo "▸ Building framework (arm64 + x86_64)…"
cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" >/dev/null
cmake --build "$BUILD_DIR/build" >/dev/null

echo "▸ Installing into $DEST/…"
rm -rf "$DEST/MediaRemoteAdapter.framework" "$DEST/MediaRemoteAdapterTestClient"
cp -R "$BUILD_DIR/build/MediaRemoteAdapter.framework" "$DEST/"
if [ -f "$BUILD_DIR/build/MediaRemoteAdapterTestClient" ]; then
  cp "$BUILD_DIR/build/MediaRemoteAdapterTestClient" "$DEST/"
  chmod +x "$DEST/MediaRemoteAdapterTestClient"
fi

# Refresh the vendored Perl script from the same checkout so it matches the build.
cp "$BUILD_DIR/bin/mediaremote-adapter.pl" "$DEST/mediaremote-adapter.pl"
chmod +x "$DEST/mediaremote-adapter.pl"

echo "✓ Adapter ready in $DEST/:"
ls -1 "$DEST"
echo
echo "Next: xcodegen generate && xcodebuild -scheme Canopy build"
