---
name: usage-limits
description: This skill should be used when the user asks "how much Claude usage do I have left", "how much Codex usage is left", "am I close to my limit", "when does my limit reset", "when does my weekly limit reset", "what's my 5-hour window at", "check my usage", "how much of my Max plan have I used", "will I hit my limit", "show my rate limits", or mentions Claude Code / Codex / GitHub Copilot plan limits, quota, rate limits or reset times. Reads the local TokenMeter board and summarizes each meter's percent used, reset time, pace projection and staleness.
version: 1.0.0
---

# Plan limits from TokenMeter

Answer questions about remaining AI coding-tool plan limits (Claude Code, Codex,
GitHub Copilot, Cursor, Grok) using the board file that the TokenMeter app
writes locally. The plugin only reads that file; it never calls vendor APIs and
never needs credentials.

## Procedure

1. Run the reader:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/board.py" limits
   ```

   If `${CLAUDE_PLUGIN_ROOT}` is not expanded, use the script at
   `../../scripts/board.py` relative to this skill's base directory. Use
   `python` or `py` if `python3` is not on PATH.

2. If it exits with code 2 and prints "No TokenMeter board found", relay that
   TokenMeter is not installed or not running, give the install link
   (https://github.com/patrickking67/tokenmeter) and the `TOKENMETER_BOARD`
   override. Do not guess usage numbers.

3. Otherwise summarize. Lead with a direct answer to the question asked, then
   the details. For each provider the output gives, per meter: `Used`, `Left`,
   `Resets` (local time and countdown), `Proj@reset` and a `Pace` note.

## Reading the numbers

- **Meters**: `Current` is the 5-hour rolling session window; `Weekly` is the
  7-day window; labels such as `Weekly · Opus` or a codename are
  model-specific weekly caps. Call `Current` "the 5-hour window" when talking
  to the user.
- **Fresh window**: when a reset time has passed, the tool shows 0% and
  "Fresh window". Say the window has reset; do not quote the old number.
- **Pace**: `Proj@reset` is `used / elapsed-fraction` of the window. Above 100%
  means the current rate would exhaust the meter before it resets; the Pace
  column then gives the projected time the limit is hit. Pace is omitted early
  in a window (<8% elapsed) or when usage is under 1%; say "too early to
  project" rather than inventing a projection.
- **Colour / overall verdict**: red (critical) at ≥90% used or ≥130%
  projected; amber (tight) at ≥70% or ≥100% projected; `ok` from 40% used or
  70% projected; otherwise `plenty`.
- **STALE**: a provider that last reported more than 6 hours ago is stale.
  Present its numbers as possibly out of date and give the age. A board-level
  WARNING means the TokenMeter app itself may not be running.
- **Notes**: some providers (e.g. GitHub Copilot) have no % meters and only a
  note such as "1,894 credits this month · no cap". Quote the note verbatim.
- Unknown vendors are skipped by the reader; do not speculate about them.

## Answer shape

Keep it short. Example:

> **Claude (Max 20x):** 5-hour window at 5% (resets today 21:40). Weekly at
> 22%, resets Wed 13:00 — on pace for ~36% by then, so plenty of room.
> **Codex (Business):** weekly at 10%, resets Sun 8:19; too early in the window
> to project.

Mention anything tight or critical first, including the projected limit-hit
time. When the user is about to start something large and headroom is tight,
suggest the `limit-aware-planning` skill's approach (lighter strategy or
deferring to the reset time).

## Related commands

- `board.py budget --vendor claude` — the same data as JSON with a one-word
  verdict (`plenty`/`ok`/`tight`/`critical`), used for planning decisions.
- `board.py activity` — token activity; see the `usage-report` skill.
