#!/bin/bash
# Builds VoxCarrelApp/build/VoxCarrel.app. Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product VoxCarrel
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/VoxCarrel.app"
# Assemble and sign outside the project folder: when the project lives in a synced
# folder (iCloud Documents), the sync service tags new folders with extended
# attributes, and codesign refuses a bundle that has them.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
STAGED="$STAGE/VoxCarrel.app"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
cp "$BIN/VoxCarrel" "$STAGED/Contents/MacOS/VoxCarrel"
cp Resources/Info.plist "$STAGED/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGED/Contents/Resources/AppIcon.icns"
xattr -cr "$STAGED"
codesign --force --sign - "$STAGED"
rm -rf "$APP"
mkdir -p build
mv "$STAGED" "$APP"
echo "Built $PWD/$APP"
