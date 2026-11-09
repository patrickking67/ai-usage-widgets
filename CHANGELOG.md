# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **App icon**: the two rings from the menu bar on a dark tile, with gradient arcs, drawn by `apps/macos/App/IconArt.swift` (`scripts/make-icon.sh` writes the icon set).
- **Shortcuts, Spotlight and Siri**: Get AI Usage, Set Keep Awake and Open TokenMeter Dashboard, with suggested phrases.
- **Dashboard analytics**: the tokens card shows the change on last week, a By tool card splits the span across Claude, Codex and Copilot, a Projects card ranks the week's repositories (worktrees count toward their repo), and a When you work heatmap shows tokens by weekday and hour with the busiest slot. The activity cache is rebuilt once to pick up each session's folder.
- **Codex workspace name** on the card ("Acme · Business"), from `chatgpt.com/backend-api/accounts/check` hourly. The token doesn't carry it.
- **Copilot's own logo** for its card, widgets and menu bar mark, in place of the generic code symbol.
- **Live Dock icon**: with Show in Dock on, the icon's rings fill to each lane's hottest window. A setting turns it off.
- **Keep Awake in the menu bar**: a small cup cut into the ring logo, outlined while waiting for an agent and filled while holding the Mac awake.
- **Popover footer** with today's tokens, this week's and its change, and when the board was last written. Command-D opens the dashboard and Command-comma Settings.
- **Settings**: a Keep Awake section, each notification kind on its own switch, and an About pane.
- **Ring logo in the menu bar.** One ring per lane (two at most), filled to its hottest window, replaces the vendor marks and percentages, which stay available in Settings, General, Menu bar.
- **Keep Awake.** A cup in the popover header holds a power assertion while Claude Code or Codex is writing a session (last 5 minutes), for one hour, or until turned off. An option keeps the screen on too. The menu bar ring shows a dot while it holds.
- **Notifications** for a window on pace to run out before its reset (from 40%), for a window used up (with when it comes back), and when a one-hour Keep Awake ends. Clicking any notification opens the dashboard, and they show while the app is in front.
- **Paused badge on widgets** when the board hasn't been written for 15 minutes, so frozen numbers don't look live. The app now rewrites the board every five minutes even when nothing changed.
- **VoiceOver.** Each meter, ring, the menu bar label, extra spend and the weekly breakdown read as one sentence: percent used, reset and pace. Vendor icons are hidden as decorative and the refresh button has a label.
- **macOS unit tests** (`apps/macos/Tests`) for every lane's response parsing, pace math and spoken text, from new synthetic fixtures in `spec/fixtures`. The test bundle is not hosted in the app, so it never reads a credential or makes a request.
- **One check command**, `scripts/check.sh`: shellcheck, actionlint, JSON and PowerShell syntax, plugin tests, Windows core tests, macOS unit tests and an unsigned build. CI runs it.
- Docs for agents and contributors (`AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `llms.txt`), a data sources and privacy table in the README, issue and PR templates, Dependabot for GitHub Actions, and a local preview config for the static page.
- **Rings widget.** Small: nested rings, one per lane, with the hottest number in the middle. Medium: a ring per lane with its reset. Vendor colour tells the lanes apart; vibrant mode draws them bright.

- **Live Codex limits** from the endpoint Codex's own `/status` reads, so the card is current without a Codex turn. Session rollouts remain the fallback.
- **Where the week went**: Claude's weekly window split by surface (Cowork, Claude Code, Chats…) under the Claude card.

### Fixed
- TokenMeter didn't come back after a restart. It registered as a login item only when the status read exactly `notRegistered`. It now registers once on first launch, checks the result, and falls back to a per-user LaunchAgent that also restarts it after a crash. A second copy started alongside quits.
- The Copilot lane stayed hidden when `gh` was installed outside Homebrew or `/usr` (pixi, Nix, `~/.local/bin`).
- Bars and rings: a window that's used up reads "Limit" and when it comes back instead of 100%, without a pace note, a lane at 0% no longer draws a dot, and each ring has the pace tick the bars have.
- Cursor: a usage summary with a billing cycle end but no start crashed the app. Either end missing now falls back to a 30-day window.
- The static page's install steps changed into a `tokenmeter` folder that a clone does not create. It also gains a main landmark, skip link, visible focus, reduced-motion support and AA contrast for muted text.
- The Windows core tests ran under Invoke-Pester, which counted 0 tests because the file has no Describe blocks. CI now runs the script directly so its failure count is the exit code.
- The status line defaults `FAST` and `THINK` when jq's output is missing.
- Claude's account and plan come from Anthropic's profile endpoint for the signed-in token. `~/.claude.json` keeps the previous account after a switch, so a personal plan could show as a team one.
- Claude windows come from the `limits` list the Claude app draws, with model scopes ("Weekly · Fable"), instead of internal codenames.
- Codex's plan follows the live account, and `promax` reads "Pro Max".

### Changed
- CI is one macOS job running `scripts/check.sh` plus a Windows job for the core tests, on `actions/checkout@v5`.
- The README no longer links a GitHub Pages site; there isn't one. `docs/` is a static page to preview locally.
- Limits refresh every 60 seconds and whenever the popover opens (at most every 20 seconds per vendor).
- The Claude lane is named "Claude": its limits cover the whole account, not just Claude Code.
- Clicking any widget opens the dashboard.
- Widgets are named Rings, Limits and Activity, and their descriptions cover every lane.
- The small Limits widget shows at most three lanes, so it never overflows.

## [1.0.0] - 2026-09-27

Renamed to **TokenMeter**. The repo is restructured into one app per platform around a documented board file.

### Added
- **GitHub Copilot lane.** The premium-request allowance comes from `copilot_internal/user` via the `gh` CLI, so the token never leaves gh. Uncapped Business seats show credits used instead of a bar.
- **VS Code agent activity.** Copilot Chat sessions (`chatSessions/*.json[l]`) feed the token charts, deduplicated by `requestId`.
- **Cursor and Grok lanes (beta)**, built from the vendors' own clients. They're marked experimental until checked against a real account.
- **Dashboard window**: limits beside 30 days of activity, headline stats, drivers, models and 24h breakdowns, with a 7/30-day toggle. Open it from the popover or `tokenmeter://dashboard`.
- **Settings window** (General, Lanes, Advanced): per-lane on/off, account names, menu-bar lanes, alerts, Dock icon, login item.
- **Windows client** (`apps/windows`): PowerShell 7 and WPF tray app, desktop widget and settings, writing the same board.
- **Claude Code plugin** (`plugin/`): `/tokenmeter:usage`, `/tokenmeter:report`, limit-aware planning and optimisation skills, a session-start hook, and 8 tests.
- **Clickable Claude Code status line** (`extras/`): folder, branch, vendor and dashboard links over OSC 8, pace warnings only when a window is projected past 100%, and Codex, Copilot and Cursor on row 2.
- **Marketing site** in `docs/`, served by GitHub Pages, with screenshots rendered from an anonymised demo board (`TOKENMETER_BOARD=… TokenMeter --render`).

### Changed
- Each vendor is now a `ProviderSource`, and the collector only orchestrates them.
- Activity keeps 31 days (the board carries 30); model shares stay 7-day.
- `board.json` gains the `copilot` vendor, the `note` field and `copilot24h`.
- Settings from the ClaudeUsage bundle are migrated once.

### Fixed
- The Claude plan reads the org tier (`default_claude_max_20x` → "Max 20x"), not just the user tier.
- Codex no longer shows OpenAI API-platform org names as the ChatGPT workspace.
- No Keychain prompts: Claude's token is read via `/usr/bin/security`, which the item already trusts.
- Unknown cache figures show as blank, not "0%".

## Before 1.0.0

Earlier versions were a private prototype under another name. 1.0.0 is the first release as TokenMeter.
