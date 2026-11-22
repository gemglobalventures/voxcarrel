#!/bin/bash
# Runs both test suites twice: as a debug build and as an optimised (release) build.
# The release run matters: one fault so far (lookup results lost) only showed when optimised.
set -euo pipefail
cd "$(dirname "$0")/../.."
for package in VoxCarrelCore VoxCarrelApp; do
  echo "== $package (debug)"
  swift test --package-path "$package" 2>&1 | tail -1
  echo "== $package (release)"
  swift test --package-path "$package" -c release -Xswiftc -enable-testing 2>&1 | tail -1
done
