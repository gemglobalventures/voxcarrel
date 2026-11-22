#!/bin/bash
# Runs both test suites twice: as a debug build and as an optimised (release) build.
# The release run matters: one fault so far (lookup results lost) only showed when optimised.
#
# For each run, every line that reports a failure (marked ✘) is printed, cut to 300
# characters, and then the run's last line. All four runs are made whatever fails; the
# script ends with a non-zero status if any of them failed.
set -uo pipefail
cd "$(dirname "$0")/../.."
log=$(mktemp)
trap 'rm -f "$log"' EXIT
failed=0

run() {
  local name=$1
  shift
  echo "== $name"
  if ! "$@" >"$log" 2>&1; then
    failed=1
  fi
  grep -F "✘" "$log" | cut -c1-300
  tail -1 "$log"
}

for package in VoxCarrelCore VoxCarrelApp; do
  run "$package (debug)" swift test --package-path "$package"
  run "$package (release)" swift test --package-path "$package" -c release -Xswiftc -enable-testing
done

if [ "$failed" -ne 0 ]; then
  echo "== FAILED: at least one run did not pass"
fi
exit "$failed"
