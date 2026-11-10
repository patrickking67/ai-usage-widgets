---
name: usage-report
description: This skill should be used when the user asks for a "weekly usage report", "usage report", "token report", "what did I spend my tokens on", "what drove my Claude usage this week", "summarize my AI usage", "how was my usage this week vs last week", "cache efficiency report", or wants a written markdown summary of Claude Code / Codex / GitHub Copilot token activity with recommendations. Builds the report from the local TokenMeter board.
version: 1.0.0
---

# Weekly usage report

Produce a concise markdown report of the user's AI coding-tool token activity
on this machine: what drove usage, how efficient it was, how this week compares
with previous weeks, and concrete recommendations backed by the numbers.

## Gather data

Run both (use `python`/`py` if `python3` is missing; if `${CLAUDE_PLUGIN_ROOT}`
is not expanded, the script is `../../scripts/board.py` relative to this skill):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" activity --days 30
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" limits
```

- `activity --days 30` prints the daily totals (the board keeps up to 30 days;
  older boards keep 7, in which case the reader says so), a **Weekly trend**
  table of 7-day blocks with "this week vs average of previous weeks", top
  drivers, subagent and long-context shares, a 24-hour breakdown with cache hit
  rate and tokens per request, the model mix (last 7 days) and tips.
- `limits` gives current plan headroom to frame the report.
- If the reader exits with code 2 (no board), explain that TokenMeter must be
  installed and running (https://github.com/patrickking67/tokenmeter) and stop.
  If the board has no `activity` yet, say the first log scan has not happened.

For exact values (e.g. to compute percentages), `board.py json` prints the raw
board. Never invent numbers not present in the output.

## Interpret

- **Total tokens** = input + output + cache read + cache write (how the vendors
  count). Cache reads usually dominate Claude totals; a large total with a high
  cache hit rate is cheaper than it looks, so say so.
- **Cache hit** = cache read / (input + cache read + cache write). ≥90% is
  healthy; <70% signals context churn (idle gaps >5 min, editing early context,
  switching models mid-session).
- **Long-context share**: share of Claude tokens sent with >150k context.
  Above ~50% means sessions run long without `/compact` or `/clear`.
- **Subagent share**: share of Claude tokens from subagents. Above ~50% means
  fan-out is the main cost driver.
- **Drivers** (MCP servers, skills, subagents): share of Claude tokens spent in
  session-hours while that driver was active. Shares **overlap** and are
  correlation, not attribution — write "active during X% of token volume", never
  "caused X%".
- **Trend**: use the Weekly trend block; call out peak days and whether this
  week is up or down vs the previous weeks' average.

## Report template

Write the report in this shape (omit sections without data):

```markdown
# AI usage report — <first day> to <last day>

**Headline:** <one sentence: total tokens, change vs previous weeks, current headroom>

## Where the tokens went
| Tool | 7-day tokens | Share |
| Top models: ... | Peak day: ... |

## Trend
<this week vs previous weeks; notable spikes and what day>

## What drove usage
- <top 3 drivers with kind, calls, overlapping share>
- Subagents: <share>; long context: <share>

## Efficiency
- Cache hit (24 h): Claude <x>%, Codex <y>%
- Tokens per request: <n> — <interpretation>

## Plan headroom
<one line per provider/meter that matters, with reset time>

## Recommendations
1. <specific action> — because <number from the data>; expected effect.
2. ...
```

Recommendations must each cite the metric that motivates them and be concrete
(e.g. "Run `/compact` when a session passes ~100k context — 99.9% of Claude
tokens this week were sent with >150k context"). Prefer 3–5 high-impact items
over a long list. For deeper analysis, defer to the `optimize-usage` skill.

Save the report to a file only if the user asks; otherwise print it inline.
