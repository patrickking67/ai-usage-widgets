#!/bin/sh
# TokenMeter SessionStart hook.
# Prints a JSON additionalContext line only when Claude headroom is tight or
# critical; prints nothing otherwise. Never fails the session: always exit 0.
# Reads a local file only (no network), so it finishes in well under a second.

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0" 2>/dev/null)/.." 2>/dev/null && pwd)}"
SCRIPT="$ROOT/scripts/board.py"

PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] && [ -f "$SCRIPT" ] || exit 0

"$PY" "$SCRIPT" hook </dev/null 2>/dev/null
exit 0
