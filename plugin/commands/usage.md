---
description: Show Claude/Codex plan limits, resets and pace from TokenMeter
allowed-tools: Bash(python3:*), Bash(python:*), Bash(py:*)
---

TokenMeter limits, read from the local board just now:

!`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" limits 2>&1 || true`

Summarize this for the user following the tokenmeter `usage-limits` skill: lead with
anything tight or critical (including a projected limit-hit time), then one
short line per provider with the key meters and their reset times. Treat STALE
providers as possibly out of date and a "Fresh window" meter as reset. If no
board was found, relay the install instructions from the output instead of
guessing numbers. $ARGUMENTS
