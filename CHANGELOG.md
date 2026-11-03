# Changelog

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
