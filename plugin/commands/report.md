---
description: Weekly AI usage report from TokenMeter (drivers, cache, trends)
allowed-tools: Bash(python3:*), Bash(python:*), Bash(py:*)
---

TokenMeter data, read from the local board just now:

!`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" activity --days 30 2>&1 || true`

!`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" limits 2>&1 || true`

Write the weekly usage report described by the tokenmeter `usage-report` skill
from the data above: headline, where the tokens went, week-over-week trend,
drivers (shares overlap; describe them as correlation), efficiency (cache hit,
tokens per request, long-context and subagent shares), plan headroom, and 3–5
concrete recommendations that each cite the metric behind them. Use only
numbers present above. If no board was found, relay the install instructions
instead. Extra instructions from the user, if any: $ARGUMENTS
