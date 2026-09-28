#!/usr/bin/env bash
# Render every tab of the panel to PNGs, in dark and light, without opening
# anything on screen. Used to check a UI change before calling it done.
#
#   scripts/snapshots.sh [out-dir]     default: build/snapshots
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/build/Switchboard.app/Contents/MacOS/Switchboard"
OUT="${1:-$ROOT/build/snapshots}"
[[ -x "$BIN" ]] || { echo "build first: scripts/build.sh --package" >&2; exit 1; }
mkdir -p "$OUT"
for tab in agents usage system home; do
  for mode in dark light; do
    flag=""; [[ "$mode" == light ]] && flag="--light"
    "$BIN" --snapshot "$OUT/$tab-$mode.png" --tab "$tab" $flag
  done
done
