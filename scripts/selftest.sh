#!/bin/sh
# Runs the app's selftest as the app itself, so macOS checks the app's own Screen Recording
# permission. Usage: sh scripts/selftest.sh (after ./build.sh)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build.noindex/BetterMacScreenshot.app"
[ -d "$APP" ] || { echo "build first: ./build.sh"; exit 1; }
REPORT=$(mktemp /tmp/screenshottool-selftest.XXXXXX)
trap 'rm -f "$REPORT"' EXIT INT TERM
open -n -W "$APP" --args --selftest --out "$REPORT"
cat "$REPORT"
grep -q '^RESULT  all passed' "$REPORT"
