---
name: optimize-usage
description: This skill should be used when the user asks "how can I make my Claude limits last longer", "why am I burning through my usage", "reduce my token usage", "optimize my Claude Code usage", "stretch my plan", "why do I keep hitting the limit", "which MCP servers are costing me tokens", "am I using too many subagents", "improve my cache hit rate", or wants evidence-based advice to cut token consumption in Claude Code or Codex. Analyzes TokenMeter's drivers, long-context share, subagent share and cache efficiency.
version: 1.0.0
---

# Optimize usage

Give specific, evidence-based advice for stretching plan limits, derived from
the user's own TokenMeter activity data. Every recommendation must cite the
number that motivates it; skip generic advice the data does not support.

## Gather data

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" activity --days 30
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" limits
```

(Use `python`/`py` if needed; if `${CLAUDE_PLUGIN_ROOT}` is not expanded, the
script is `../../scripts/board.py` relative to this skill's base directory.
`board.py json` gives raw values.) If no board exists (exit code 2), explain
that TokenMeter must be installed and running
(https://github.com/patrickking67/tokenmeter) and stop.

## Diagnose, in this order

Work through each signal, compare it with the threshold, and keep only the
findings that trip a threshold. Order the final advice by expected impact.

### 1. Long-context share (`long context (> 150k context)`)
- ≥ 50%: the biggest lever. Every turn re-sends the whole context.
  Advice: `/compact` at natural breakpoints (or when context passes ~100k),
  `/clear` between unrelated tasks, start new sessions for new work, keep a
  short `PLAN.md`/notes file instead of relying on scrollback, and avoid
  pasting or reading whole large files.
- 20–50%: mention as secondary.

### 2. Subagent share
- ≥ 50%: fan-out dominates. Advice: fewer parallel subagents, tight briefs
  that name files and expected output, a smaller model for exploration and
  mechanical subagents, and doing small lookups inline instead of via an agent.
  Cross-check the `Subagent` drivers to name the specific agents.

### 3. Drivers (MCP servers, skills, subagents)
- Share = Claude tokens in session-hours while the driver was active. Shares
  **overlap** and show correlation, not cause. Phrase as "active during X% of
  token volume".
- An MCP server with high share and **few calls** is likely paying for its
  tool definitions on every request without being used much: suggest
  disabling it (`/mcp`) or scoping it to the projects that need it.
- An MCP server with high share and **many calls** (e.g. a desktop/file or
  browser server with thousands of calls) often returns large payloads:
  suggest narrower queries, screenshots/page text only when needed, and
  built-in Read/Grep for files.

### 4. Cache efficiency (24 h `CacheHit`)
- ≥ 90% healthy. 70–90% moderate. < 70% poor: likely idle gaps > 5 minutes
  (cache expiry), frequent model switches, or edits to early context
  (CLAUDE.md, system prompt, reordered files). Advice accordingly.

### 5. Tokens per request (24 h `Tok/req`)
- Above ~200k per request confirms very large contexts; tie it to finding 1.

### 6. Model mix (last 7 days)
- If the strongest model carries nearly all tokens and a model-specific
  weekly meter is tight in `limits`, suggest Sonnet/Haiku for routine work
  and subagents.

### 7. Trend and peaks
- From the Weekly trend and daily table: note spike days and whether usage is
  rising. Spikes often correspond to one long session or a big fan-out;
  suggest the user recall what ran that day.

## Output

```markdown
## Where your tokens go
<2–3 sentences with the key numbers>

## Top changes (highest impact first)
1. **<action>** — evidence: <metric = value vs threshold>. Expected effect: <why it helps>.
2. ...

## Already good
- <signals that are healthy, e.g. cache hit 98%>
```

Limit to 3–5 recommendations. Where the data is thin (no activity yet, 7-day
board only, zero Claude tokens), say what is missing rather than guessing.
When headroom is tight right now, point to the `limit-aware-planning` skill for
how to run the next big task.
