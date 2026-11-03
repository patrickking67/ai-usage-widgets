#!/bin/sh
# TokenMeter status-line segment (opt-in). Prints e.g. "✳ 22% · ⏳ 3h":
# the most-used Claude plan meter and the time until that meter resets.
# Prints nothing if TokenMeter's board is missing. Never exits non-zero.
#
# Enable in ~/.claude/settings.json:
#   "statusLine": { "type": "command",
#     "command": "sh /path/to/tokenmeter/scripts/statusline.sh" }

DIR="$(cd "$(dirname "$0" 2>/dev/null)" 2>/dev/null && pwd)"
# Claude Code pipes session JSON on stdin; this segment does not need it.

for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1; then
    "$cand" "$DIR/board.py" statusline </dev/null 2>/dev/null
    break
  fi
done
exit 0
