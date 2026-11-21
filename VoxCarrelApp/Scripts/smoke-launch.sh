#!/bin/bash
# Builds the app, makes a fresh demo library in a temporary folder, launches the app on
# it and checks that it is still running a few seconds later. Exits 0 or 1.
# Touches no library other than the temporary one it makes, and stops no process other
# than the copy of the app it started.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
APP="$ROOT/build/VoxCarrel.app"
BIN="$APP/Contents/MacOS/VoxCarrel"

Scripts/build-app.sh debug

# -P: the process list shows the folder's real path, not /var -> /private/var.
DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/voxcarrel-smoke.XXXXXX")" && pwd -P)"
swift run voxcarrel-demo library "$DIR"
echo "Demo library: $DIR"

# Only the app from this build folder, started on this temporary library.
quote() { printf '%s' "$1" | sed 's/[][\.*^$()+?{}|]/\\&/g'; }
PATTERN="^$(quote "$BIN") .*$(quote "$DIR")"

open -n "$APP" --args -libraryPath "$DIR"
sleep 6

if pgrep -f "$PATTERN" >/dev/null; then
    pkill -f "$PATTERN" || true
    rm -rf "$DIR"
    echo "Smoke launch passed"
    exit 0
fi
echo "Smoke launch FAILED: the app is not running. The library was left at $DIR"
exit 1
