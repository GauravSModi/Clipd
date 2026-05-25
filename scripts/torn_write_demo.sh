#!/usr/bin/env bash
# Demonstrates crash-safe recovery: corrupt the tail of a valid log, then show
# replay truncating to the last valid record while earlier history survives.
#
# Usage: scripts/torn_write_demo.sh [path-to-clipd-cli]
set -euo pipefail

CLI="${1:-./build/clipd-cli}"
if [[ ! -x "$CLI" ]]; then
  echo "clipd-cli not found at '$CLI'. Build first: cmake --build build" >&2
  exit 1
fi

LOG="$(mktemp -u "${TMPDIR:-/tmp}/clipd_demo.XXXXXX.log")"
trap 'rm -f "$LOG"' EXIT

echo "==> Adding three entries"
"$CLI" --log "$LOG" add "first entry"
"$CLI" --log "$LOG" add "second entry"
"$CLI" --log "$LOG" add "third entry"
"$CLI" --log "$LOG" stats

echo
echo "==> Log is clean"
"$CLI" --log "$LOG" replay

echo
echo "==> Simulating a crash mid-write: appending a torn record to the tail"
# A length header promising 32 payload bytes, followed by only a few bytes.
printf '\x20\x00\x00\x00\xde\xad\xbe\xef' >>"$LOG"
printf 'partial' >>"$LOG"
echo "    log size is now $(wc -c <"$LOG" | tr -d ' ') bytes (corrupted tail)"

echo
echo "==> Replaying: torn tail detected and truncated"
"$CLI" --log "$LOG" replay

echo
echo "==> Earlier history is intact"
"$CLI" --log "$LOG" list
