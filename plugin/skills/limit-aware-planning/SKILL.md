---
name: limit-aware-planning
description: This skill should be used BEFORE starting any large or long-running piece of work in Claude Code — when the user asks to "refactor the whole codebase", "migrate all files", "run several/many subagents in parallel", "fan out agents", "spin up a team of agents", "do a big refactor", "rewrite the project", "work through this backlog", "run this overnight", "keep going until done", start a long autonomous session or multi-step plan, or asks "do I have enough usage for this", "will this blow my limit", "should I wait until my limit resets", "plan this around my rate limit". Checks TokenMeter headroom and, when it is tight or critical, picks a cheaper execution strategy or proposes deferring to the exact reset time. Also applies when a TokenMeter SessionStart note says headroom is tight.
version: 1.0.0
---

# Limit-aware planning

Large tasks can exhaust a Claude plan limit halfway through, leaving work
half-applied and the user locked out until the window resets. Before committing
to an expensive execution strategy, check the real headroom recorded by
TokenMeter and size the approach to fit. The goal is not to refuse work: it is
to finish the task within the budget, or to make an informed choice about
spending it.

## When to run the check

Run it before any of these, and at most once per task (re-check only if the
task grows substantially or several hours pass):

- Spawning more than 2 subagents, or any parallel fan-out / workflow.
- Refactors, migrations or reviews touching more than ~15 files.
- Long autonomous loops ("keep going until done", overnight runs).
- Anything the user describes as big, or explicitly worries about limits.
- A TokenMeter SessionStart note is in context saying headroom is tight.

Skip it for small, bounded edits. Do not nag: when the budget is plenty, say
nothing about it (or a single line if the user asked).

## Step 1 — Read the budget

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" budget --vendor claude
```

(Use `python`/`py` if needed; if `${CLAUDE_PLUGIN_ROOT}` is not expanded, the
script is `../../scripts/board.py` relative to this skill's base directory.)

The JSON contains an overall `verdict` and `headline`, plus per meter:
`used`, `remaining`, `hoursToReset`, `resetsAtLocal`, `projectedAtReset`,
`limitHitAtLocal` / `hoursToLimit` (set when the current pace runs out before
the reset), `freshWindow`, `verdict`, and for multi-day meters
`tokensPerPercent` — a rough calibration of how many of this user's tokens
equal 1% of that meter, derived from local activity.

Verdicts: **critical** = ≥90% used or ≥130% projected; **tight** = ≥70% used or
≥100% projected; **ok** = ≥40% used or ≥70% projected; **plenty** otherwise.

Edge cases:
- `status: "no-board"` → TokenMeter is not installed/running. Proceed with the
  task normally; mention once that installing TokenMeter
  (https://github.com/patrickking67/tokenmeter) enables limit-aware planning.
- `stale: true` or `boardStale: true` → numbers may be outdated; state the age
  and treat the verdict as approximate. Do not block on stale data alone.
- `freshWindow: true` → that meter just reset; it is effectively empty.

## Step 2 — Identify the binding meter

Different meters call for different fixes:

| Binding meter | What it means | Best lever |
| --- | --- | --- |
| `Current` (5-hour) | Short-term burst limit | Pace the work or wait for the 5-hour reset (usually < 5 h away) |
| `Weekly` | The weekly allowance | Reduce total tokens: fewer/leaner subagents, smaller context, cheaper models |
| Model-specific weekly (e.g. `Weekly · Opus`, a model codename) | Cap on one model only | Move bulk work to a model outside that cap (e.g. Sonnet or Haiku) |

If only the 5-hour window is tight while the weekly meter is fine, waiting
`hoursToReset` hours is often the cheapest answer. If the weekly meter is
tight, waiting only helps if its reset is soon.

## Step 3 — Estimate the task's cost

Estimate roughly, in tokens, then convert with `tokensPerPercent` when it is
present. Use the rules of thumb in `references/cost-model.md` (turns × average
context per turn; each subagent pays its own context from scratch). State the
estimate as a range and as a share of `remaining`, e.g. "~150–300M tokens ≈
0.5–1% of the weekly meter; 22% left". If `tokensPerPercent` is null, reason
qualitatively from the verdict instead of inventing a precise figure.

## Step 4 — Choose a strategy by verdict

**plenty** — Proceed with the best strategy for quality. No budget talk needed.

**ok** — Proceed, with sensible economy: cap parallel subagents at ~4, give
each a narrow brief, keep the main context lean.

**tight** — Switch to a lighter strategy and say so in one or two lines before
starting:
- Run sequentially or with at most 2 subagents instead of a wide fan-out.
- Use a smaller model (Sonnet/Haiku) for search, file reading, test running and
  other mechanical subtasks; keep the strongest model for design decisions.
- `/compact` (or start fresh with a written plan) before a long task; avoid
  re-reading large files; grep for the relevant region instead.
- Scope first: do the highest-value slice now, and write the remaining steps
  to a plan file (e.g. `PLAN.md`) so work can resume cleanly after the reset.
- Disable MCP servers the task does not need (`/mcp`), since their tool
  definitions are re-sent on every request.

**critical** — Stop before starting the expensive part and ask the user,
presenting concrete options:
1. **Minimal now** — the smallest useful slice that fits, with the rest
   written to a plan file.
2. **Defer** — start after the reset at `resetsAtLocal` (in `hoursToReset`
   hours); offer to prepare the plan now so the run starts immediately then.
3. **Proceed anyway** — accept the risk of hitting the limit, noting
   `limitHitAtLocal` if set. Checkpoint frequently (commit or write progress)
   so a lockout does not strand half-applied changes.

Always use the exact reset time and countdown from the JSON (e.g. "resets Wed
13:00, in 2 d 16 h"), never a vague "later".

## Step 5 — Tell the user briefly, then work

Format for tight/critical:

> **Budget check (TokenMeter):** Claude weekly at 91%, resets Wed 13:00 (in 2 d
> 16 h); at the current pace it runs out ~Tue 19:50. This refactor is roughly
> 3–5% of the weekly meter, so I'll do it sequentially with Sonnet subagents
> for file scans, and keep Opus for the design. Say "full speed" to use the
> parallel plan instead.

The user can always override. Respect an explicit "ignore the limit" and do not
re-raise it for the same task.

## During long tasks

For work spanning hours, re-run `budget` at natural checkpoints (e.g. between
phases). If the verdict worsens to critical mid-task, finish the current atomic
step, checkpoint, and offer the options above instead of pushing into a lockout.

## Additional resources

- **`references/cost-model.md`** — token cost rules of thumb for sessions,
  subagents, context size and caching, with a worked estimate.
