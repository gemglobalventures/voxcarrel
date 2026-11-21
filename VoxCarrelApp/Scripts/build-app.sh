#!/bin/bash
# Builds VoxCarrelApp/build/VoxCarrel.app. Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product VoxCarrel
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/VoxCarrel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VoxCarrel" "$APP/Contents/MacOS/VoxCarrel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
