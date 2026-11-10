# TokenMeter plugin for Claude Code

See your AI coding-tool plan limits and token activity inside Claude Code, and
let Claude plan large tasks around the headroom you actually have.

The plugin reads the **board** file that the TokenMeter app writes
(`spec/board.md` in the TokenMeter repo). It never calls vendor APIs, never
reads credentials and never writes anything.

## Requirements

- The TokenMeter app, installed and running:
  https://github.com/patrickking67/tokenmeter
- Python 3 on `PATH` (`python3`, `python` or `py`); standard library only.

Board lookup order:

| Order | Path |
| --- | --- |
| 1 | `$TOKENMETER_BOARD` (if set, only this path is used) |
| 2 | Windows: `%LOCALAPPDATA%\TokenMeter\board.json` |
| 3 | macOS/Linux: `~/.cache/tokenmeter/board.json` |
| 4 | Legacy: `~/.cache/claude-usage/board.json` |

## Install

```text
/plugin marketplace add patrickking67/tokenmeter
/plugin install tokenmeter@tokenmeter
```

For local development: `claude --plugin-dir ./plugin`.

## What you get

### Commands

| Command | Does |
| --- | --- |
| `/tokenmeter:usage` | Plan limits per tool: % used, reset time, pace projection, staleness |
| `/tokenmeter:report` | Weekly usage report: trend, drivers, cache efficiency, recommendations |

### Skills (Claude uses these automatically)

| Skill | Triggers on |
| --- | --- |
| `usage-limits` | "how much Claude usage do I have left", "when does my limit reset" |
| `usage-report` | "weekly usage report", "what drove my usage this week" |
| `limit-aware-planning` | Before big refactors, many parallel subagents, long/overnight runs; "do I have enough usage for this" |
| `optimize-usage` | "make my limits last longer", "why am I burning through usage" |

`limit-aware-planning` checks the budget before expensive work. With plenty of
headroom it stays out of the way; when headroom is **tight** it switches to a
lighter strategy (fewer parallel subagents, smaller models for mechanical
subtasks, compacting context, scoping and writing a resumable plan); when it is
**critical** it stops and offers: a minimal slice now, deferring to the exact
reset time, or proceeding knowingly. You can always override.

### SessionStart hook

At session start, if a Claude meter is tight or critical, one line is added to
Claude's context, for example:

```text
TokenMeter: Claude weekly limit at 93%, on pace for 131% by reset (limit ~Mon 5:43), resets Tue 21:37 — prefer lighter strategies; defer large fan-outs until after reset.
```

Otherwise it prints nothing. It reads one local file, takes ~35 ms, has a 5 s
timeout, always exits 0, and stays silent if the board is missing, unreadable
or older than 24 h, or if Python is unavailable.

### Status line (opt-in)

`scripts/statusline.sh` prints a compact segment such as `✳ 22% · ⏳ 3d`: the
most-used Claude meter and the time until it resets. It is not enabled
automatically. To use it, point your status line at the installed plugin copy
(find the path with `/plugin`), e.g. in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh ~/.claude/plugins/cache/tokenmeter/tokenmeter/1.0.0/scripts/statusline.sh"
  }
}
```

To combine it with an existing status line, call the script from your own and
append its output.

## Verdicts and pace

Pace follows the board spec: with `e = elapsed / window` (skipped when
`e < 0.08` or `used < 1%`), projected at reset = `used / e`, and the limit is
hit at `now + (100 − used) / (used / (e × window))` if that is before the reset.
A meter whose reset time has passed shows 0% ("Fresh window"). A provider that
has not reported for 6 h is marked stale.

| Verdict | Rule |
| --- | --- |
| critical | ≥ 90% used or ≥ 130% projected (red) |
| tight | ≥ 70% used or ≥ 100% projected (amber) |
| ok | ≥ 40% used or ≥ 70% projected |
| plenty | otherwise |

## CLI

The skills drive `scripts/board.py`, which also works on its own:

```bash
python3 scripts/board.py limits               # table of providers and meters
python3 scripts/board.py activity [--days N]  # activity (default 7 days; board keeps up to 30)
python3 scripts/board.py budget [--vendor claude]  # JSON headroom + verdict
python3 scripts/board.py json                 # raw board
python3 scripts/board.py path                 # which board file is used
```

Exit code 2 means no usable board (the message explains how to install
TokenMeter). `TOKENMETER_NOW=<unix seconds>` evaluates the board at a fixed
time, which is useful for testing against `spec/fixtures/board.json`.

## Privacy

Everything stays on your machine. The board holds percentages, reset times and
token counts; the plugin reads it and prints summaries into your Claude Code
session only.

## License

MIT © Patrick King
