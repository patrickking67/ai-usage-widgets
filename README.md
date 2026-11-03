# TokenMeter

**Every AI coding plan limit on one meter.** TokenMeter shows how much of your Claude Code, Codex, GitHub Copilot and Cursor plans you have left, whether you're on pace to run out before the reset, and what's actually spending your tokens.

![TokenMeter dashboard](docs/img/shot-dashboard-dark.png)

- **Pace, not just percent.** Every bar has a notch where even use would put you. Past it, the bar turns amber, and a flame appears when you're projected to run out before the reset.
- **Where the tokens went.** 30 days of per-vendor tokens from local logs, the input/output/cache breakdown, and the MCP servers, skills and subagents that were running while your limit dropped.
- **Everywhere you look.** A menu bar app, a dashboard window and desktop widgets on macOS. A tray app and desktop widget on Windows. A plugin and a clickable status line inside Claude Code.
- **Reads, never writes.** It borrows the sign-ins your tools already have, never refreshes or stores a token, and has no server or telemetry.

Site: <https://patrickking67.github.io/ai-usage-widgets>

## Lanes

| Lane | Limits | Activity |
| --- | --- | --- |
| Claude Code | Status line feed plus Anthropic's usage endpoint, using Claude Code's own sign-in (read with `/usr/bin/security`, so there are no Keychain prompts). Covers the 5-hour, weekly and per-model windows and extra spend. | `~/.claude/projects` transcripts |
| Codex | The `rate_limits` Codex records after every turn | Codex session rollouts |
| GitHub Copilot | Premium-request allowance via `gh api /copilot_internal/user`. Uncapped seats show credits used. | VS Code agent-mode chat sessions |
| Cursor · beta | Monthly usage pool and on-demand spend, using Cursor's local sign-in | — |
| Grok · beta | The SuperGrok credit pool from the `grok` CLI's billing endpoint | — |
| Microsoft 365 Copilot | No lane: Microsoft exposes Copilot usage only to tenant admins, with no per-person limit to show. | — |

Beta lanes follow the vendors' own clients but haven't been checked against a real account, so their cards say so. Sources and fields for every lane are in [`spec/board.md`](spec/board.md) and [`spec/providers.md`](spec/providers.md).

## Install

### macOS 14+

```bash
brew install xcodegen
git clone https://github.com/patrickking67/ai-usage-widgets
cd ai-usage-widgets/apps/macos
echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Config/Local.xcconfig   # needed for the widgets
xcodegen generate
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/TokenMeter.app /Applications/TokenMeter.app
open /Applications/TokenMeter.app
```

Then add the **Rings**, **Limits** and **Activity** widgets from the desktop's Edit Widgets menu. Open the dashboard from the popover's **Dashboard** button, with `open tokenmeter://dashboard`, or by Cmd-clicking **↗ Dashboard** in the Claude Code status line.

### Windows 10 / 11

See [`apps/windows/README.md`](apps/windows/README.md). It's a PowerShell 7 + WPF tray app with a desktop widget, and it writes the same board to `%LOCALAPPDATA%\TokenMeter\board.json`.

### Claude Code plugin

```
/plugin marketplace add patrickking67/ai-usage-widgets
/plugin install tokenmeter@tokenmeter
```

| | |
| --- | --- |
| `/tokenmeter:usage` | Limits, pace and the hottest window, with a verdict |
| `/tokenmeter:report` | Weekly report: vendors, models, drivers, week over week |
| `limit-aware-planning` skill | Before a big fan-out, checks headroom and sizes the plan to fit |
| `optimize-usage` skill | Concrete habits to stretch a limit, from your own data |
| Session-start hook | Speaks up only when a Claude window is tight |

### Claude Code status line

[`extras/claude-statusline.sh`](extras/claude-statusline.sh) is a two-row status line:

```
Opus 5.5 · High   ▸ my-app  ⎇ main +2 ~1   ◑ 41% ctx   +120 −30   $4.21 · 1h12m
✳ Acme · Team  5h ━━━╸──── 37% 4h13m  wk ━━╸───── 38% Tue   ◎ Codex wk 30%   ⌬ Copilot 1.9k cr   ↗ Dashboard
```

Cmd-click the folder, the branch, any vendor or **Dashboard**. It also feeds TokenMeter the freshest Claude limits on every turn. To install it:

```bash
cp extras/claude-statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
```

Then set `"statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 10}` in `~/.claude/settings.json`.

## How it fits together

```
 vendor sign-ins & local logs ──▶  TokenMeter (macOS / Windows)  ──▶  board.json  ──▶  widgets
                                        ▲                                  │
       Claude Code status line ─────────┘ (usage.json)                     ├──▶  Claude Code plugin
                                                                           └──▶  status line row 2
```

Everything reads one documented file, [`board.json`](spec/board.md): `~/.cache/tokenmeter/board.json` on macOS, `%LOCALAPPDATA%\TokenMeter\board.json` on Windows, or `$TOKENMETER_BOARD`. Readers skip vendors they don't know, so a new lane never breaks an older client.

```
apps/macos      SwiftUI menu bar app, dashboard, settings, WidgetKit extension
apps/windows    PowerShell 7 + WPF tray app and desktop widget
plugin/         Claude Code plugin: board.py, skills, commands, hook
extras/         Claude Code status line
spec/           board.json contract, provider research, fixtures
docs/           Marketing site (GitHub Pages)
```

## Privacy

- Tokens are read when a request needs them and never logged, cached, refreshed or written back. Refreshing from a second process would rotate the grant and sign your real tools out.
- Copilot requests are made by `gh`, so the GitHub token never enters TokenMeter.
- Activity comes from files on this machine. Requests go only to the vendor endpoints listed in the spec.

## License

MIT. Not affiliated with Anthropic, OpenAI, GitHub, Microsoft, Anysphere or xAI.
