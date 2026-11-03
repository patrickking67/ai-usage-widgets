# Token cost model for planning

Rough rules for estimating what a task will cost before running it. Treat all
figures as order-of-magnitude; the goal is to tell a 0.5% task from a 15% task.

## How tokens accrue

- **Every turn re-sends the whole context.** A turn's cost is roughly the
  current context size (mostly as cache reads) plus the new output. A session
  sitting at 150k context pays ~150k tokens per tool call.
- **Session cost ≈ turns × average context.** 60 tool calls at an average of
  80k context ≈ 5M tokens.
- **Caching lowers the price, not the count.** Cache reads are counted in
  TokenMeter totals and dominate them; plan meters weight them more cheaply
  than fresh input, which is why `tokensPerPercent` from the board (which is
  based on this user's own mix) is the best converter available.
- **Cache misses are expensive.** Idle gaps longer than ~5 minutes, switching
  models, or editing early context force a cache write of the whole prefix.

## Subagents

- Each subagent starts its own context: system prompt, tool definitions
  (including every enabled MCP server's tools) and its brief — typically
  15–40k tokens before doing anything.
- A typical exploration subagent: 15–40 turns at 30–80k context ≈ 0.5–3M
  tokens. A subagent that edits code and runs tests: 1–6M tokens.
- N parallel subagents cost ~N× a single one; parallelism saves wall-clock
  time, not tokens. Fan-out also adds orchestration turns in the main session.
- Smaller models (Sonnet, Haiku) for mechanical subagents cut cost against
  model-specific caps and usually against the weekly meter too.

## Context size

- Long-context turns (>150k) are the most common hidden cost: a session that
  drifts to 300k context pays double per turn compared with 150k.
- `/compact` typically shrinks context to 10–30k; `/clear` to near zero. Doing
  it between phases of a big task is often the single cheapest saving.
- Reading a large file costs its size once as input, then again on every later
  turn while it stays in context. Prefer grep + targeted reads.

## Converting to plan percentages

1. Estimate tokens: `turns × avg_context` for the main session plus
   `subagents × per_subagent`.
2. Divide by `tokensPerPercent` for the binding multi-day meter (from
   `board.py budget`). Example: 8 subagents × 2M + main session 6M = 22M tokens;
   with `tokensPerPercent` = 300M, that is ~0.07% of the weekly meter.
3. Compare with `remaining` and with the pace projection. A task that is
   small in absolute terms can still matter when `projectedAtReset` is already
   above 100%, because it moves `limitHitAt` earlier.
4. The 5-hour `Current` window has no calibration; judge it by its verdict and
   by how quickly it has been filling (`used` vs elapsed time).

## Worked example

Weekly meter at 88% (tight), resets in 30 h, `tokensPerPercent` = 250M. The
user asks for a 40-file migration with 10 parallel subagents.

- Estimate: 10 × 3M + main 10M ≈ 40M tokens ≈ 0.16% — fits comfortably.
- But the 5-hour window is at 75% with 3 h to reset: a 10-way burst may hit
  it. Choose: 3 subagents at a time on Sonnet, batches of ~13 files, main
  session compacts between batches. Mention the 5-hour reset time in case the
  user prefers to wait and run it wide.
