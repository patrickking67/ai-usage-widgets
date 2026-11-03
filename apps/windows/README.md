# TokenMeter for Windows

TokenMeter shows how much of your AI coding plans you have left, and what is
using them up. It covers Claude Code, Codex and GitHub Copilot. It lives in
the notification area, and has a desktop widget and a main window. It writes
the same `board.json` as the macOS app (see [`spec/board.md`](../../spec/board.md)),
so the Claude Code plugin and other TokenMeter clients read the same numbers.

It is plain PowerShell and WPF: nothing to compile, no modules to install, and
no dependencies beyond what Windows already has.

## What you get

- **Tray icon.** The highest percentage across your plans, coloured by pace.
  Hover for every provider. Left-click opens the window; right-click gives
  Open, Show widget, Settings, Refresh and Quit.
- **Main window, Limits tab.** One card per provider shows the account and
  plan, and whether the numbers are live or how old they are ("4d ago",
  dimmed once past six hours). Each window gets a bar. The notch on the bar
  marks even use across the window: fill past it means you are running hot.
  Under each bar is "Resets in 2h 13m", then either "On pace for 64%" or,
  when the current rate runs out before the reset, "Limit in 1h 20m".
  Claude's pay-as-you-go spend shows when it is switched on.
- **Main window, Activity tab.** Tokens per day for the last 7 or 30 days,
  stacked by vendor. Under the chart:
  - what drove Claude Code's usage in the last 24 hours (MCP servers, skills
    and subagents, by share of tokens spent while each was active);
  - 24-hour input, output and cache tables;
  - tokens by model;
  - one tip, picked from the strongest signal.
- **Desktop widget.** A small card that shows each provider's hottest window.
  It is borderless and draggable, and remembers where you put it. It can stay
  above other windows, and it stays out of Alt+Tab. Double-click it to open
  the main window.
- **Alerts.** A notification at 80% and at 95% of a window, and another when
  a window that was nearly spent resets. Each fires once per window, even
  across restarts.
- **Dark and light** follow the Windows app theme and switch live.

## Install

Requirements:

- Windows 10 or 11.
- Windows PowerShell 5.1, which ships with Windows. PowerShell 7 is used if
  it is installed, and makes the first log scan several times faster.
- GitHub Copilot limits only: the [GitHub CLI](https://cli.github.com/),
  signed in with `gh auth login`.

Install from the `apps/windows` folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -StartAtLogin
```

This copies the app to `%LOCALAPPDATA%\Programs\TokenMeter`, adds a Start
menu shortcut and launches it. `-StartAtLogin` adds a per-user Run entry;
you can also turn that on or off in Settings. Pass `-NoLaunch` to install
without starting. No admin rights are needed.

To try it without installing:

```powershell
wscript .\Start-TokenMeter.vbs
```

To uninstall:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\TokenMeter\uninstall.ps1"
```

This keeps `%LOCALAPPDATA%\TokenMeter`, which holds the board, settings and
scan cache. Add `-RemoveData` to delete that folder too.

## What it reads

| Source | Used for | How |
| --- | --- | --- |
| `%USERPROFILE%\.claude\.credentials.json` (or `CLAUDE_CONFIG_DIR`) | Claude plan limits | Reads `claudeAiOauth.accessToken` and sends it only to `api.anthropic.com/api/oauth/usage`. An expired token is skipped. At most every 3 minutes, and 30 minutes after a 429. |
| `%USERPROFILE%\.claude.json` | Claude account and plan | `oauthAccount`: organisation type and rate-limit tier. No secrets. |
| `%USERPROFILE%\.claude\projects\**\*.jsonl` | Activity | Token counts and tool names from assistant messages. |
| `%USERPROFILE%\.codex\sessions\**\rollout-*.jsonl` (or `CODEX_HOME`) | Codex limits and activity | The newest `rate_limits` event, and `token_count` events. |
| `%USERPROFILE%\.codex\auth.json` | Codex plan | Only the `chatgpt_plan_type` claim, decoded locally from the id_token. |
| `gh api /copilot_internal/user` | Copilot limits | Run through the GitHub CLI, which keeps its own token. Every 5 minutes. |
| `%APPDATA%\Code\User\workspaceStorage\*\chatSessions`, `globalStorage\emptyWindowChatSessions` | Copilot activity | Prompt and completion token counts per request. VS Code and VS Code Insiders. |

The Codex id_token lists `organizations`, but those are OpenAI API platform
organisations, not your ChatGPT workspace, so TokenMeter never shows them.
The workspace name is not in the token at all. On a workspace plan you see
only the plan name, unless you type the workspace name into Settings.

## What it writes

Everything goes to `%LOCALAPPDATA%\TokenMeter`:

| File | Contents |
| --- | --- |
| `board.json` | The board. Set `TOKENMETER_BOARD` to write it somewhere else. Replaced atomically. |
| `activity-cache.json` | Byte offsets and hourly totals per log file, so each scan reads only new lines. |
| `settings.json`, `alerts.json` | Your settings, and which alerts have already fired. |
| `tokenmeter.log` | Errors, kept under 1 MB. It never contains a token. |

## Privacy

- **Read only, credentials included.** TokenMeter never writes, refreshes
  or stores a credential. Refreshing Claude Code's OAuth token from a
  second process would rotate the grant and sign every Claude Code session
  out. So an expired token is left alone, and the app shows "Waiting for
  Claude Code to renew its sign-in" until Claude Code refreshes it.
- **Local.** Logs are read on this machine and never leave it. TokenMeter
  makes only two network requests: the Claude usage call above, and `gh`'s
  own call to GitHub. It has no telemetry and no update checks.
- **This machine only.** Activity covers what the local logs record. Usage
  on claude.ai, chatgpt.com, github.com or other computers is not included.
  The plan limits are account-wide, because the vendors report them that way.

## Settings

Open Settings from the tray menu or the window's gear icon:

- Alerts at 80%, 95% and when a window resets.
- Read Claude limits directly.
- Start when you sign in.
- Show the widget at startup.
- Keep the widget above other windows.
- Turn each provider on or off.
- Workspace names for Codex and Copilot.

The file also accepts `claudeAccountName`, to override the name on the Claude
card.

## Development

`TokenMeter.Core.psm1` holds all the data logic and no UI. It runs under
`pwsh` on any platform, so you can work on it on macOS or Linux:

```powershell
pwsh -NoProfile -File tests/Core.Tests.ps1
```

The tests run against `spec/fixtures` and synthetic logs in a temp folder.
They never use the network or real credentials. To look at your own activity:

```powershell
Import-Module ./TokenMeter.Core.psm1
$p = Get-TMPaths
Invoke-TMActivityScan -ClaudeProjectsDir $p.ClaudeProjects -CodexSessionsDir $p.CodexSessions `
    -VSCodeUserDirs $p.VSCodeUserDirs -CachePath ./activity-cache.json
```

`TokenMeter.ps1` is the WPF shell and needs Windows. The main files:

| File | Role |
| --- | --- |
| `TokenMeter.Core.psm1` | Limits, account, activity scan, pace, alerts, board. No UI. |
| `TokenMeter.ps1` | Tray icon, main window, widget, settings, background runspaces. |
| `Start-TokenMeter.vbs` | Hidden launcher. Prefers PowerShell 7 and falls back to 5.1. |
| `install.ps1`, `uninstall.ps1` | Per-user install and removal. |
| `tests/Core.Tests.ps1` | Core tests. Plain PowerShell; Pester is not needed. |

## Limitations

- **First scan.** The first scan of a month of busy logs takes about a
  minute on PowerShell 7 (about 4 GB in 30 seconds on a fast machine), and
  longer on Windows PowerShell 5.1. It runs in the background, and later
  scans read only appended lines. The Activity tab says so while it waits.
- **Stale Codex numbers.** Codex limits are only as fresh as the last Codex
  session, because Codex writes them to its logs only while it runs. Old
  figures are dimmed and show their age. The all-clear alert still fires
  when the reset time passes.
- **Copilot activity comes from VS Code chat sessions only.** It is prompt
  plus completion tokens; there is no cache breakdown. Copilot in other
  editors or on github.com is not counted. The Copilot quota endpoint is
  GitHub's internal one, and it may change.
- **No status line.** Claude limits come from the usage endpoint alone. The
  macOS app also merges figures from a Claude Code status line script;
  that script does not exist on Windows.
- **Notifications are balloon tips.** They come from the tray icon and are
  not toast notifications with Action Center history, which would need a
  registered app ID.
- **Pace depends on the reset time.** The vendors report a reset time, not
  a window start, so pace is worked out from the reset time and the window
  length.
