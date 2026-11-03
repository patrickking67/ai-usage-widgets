# TokenMeter (ai-usage-widgets)

Shows AI coding plan limits (Claude, Codex, Copilot, Cursor, Grok) on one meter: a macOS menu bar app with WidgetKit widgets, a Windows PowerShell + WPF tray app, and a Claude Code plugin. Start at `README.md`. The data contract every client shares is `spec/board.md`.

## Commands

| Task | Command | Notes |
| --- | --- | --- |
| Plugin tests | `python3 -m unittest discover -s plugin/tests -v` | `board.py` against `spec/fixtures`. Standard library only |
| Manifest check | `python3 -m json.tool plugin/.claude-plugin/plugin.json > /dev/null && python3 -m json.tool .claude-plugin/marketplace.json > /dev/null` | Same as CI |
| Windows core tests | `pwsh -NoProfile -File apps/windows/tests/Core.Tests.ps1` | Plain PowerShell, runs on macOS too. Exit code = failures. CI runs it through Pester |
| macOS build (unsigned) | `cd apps/macos && xcodegen generate && xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build` | Needs Xcode and `brew install xcodegen`. Takes a few minutes |
| macOS build (with widgets) | Same, without `CODE_SIGNING_ALLOWED=NO` | Needs `apps/macos/Config/Local.xcconfig` with `DEVELOPMENT_TEAM`. macOS only loads widgets signed with a real team |

No linter or formatter is configured.

## Layout

| Path | What it is |
| --- | --- |
| `apps/macos/` | SwiftUI app (`App/`), shared views and models (`Shared/`), WidgetKit extension (`Widget/`). `project.yml` is the XcodeGen source; the `.xcodeproj` is generated and gitignored |
| `apps/macos/App/Providers/` | One source per vendor lane |
| `apps/windows/` | `TokenMeter.Core.psm1` (logic), `TokenMeter.ps1` (UI), install scripts, `tests/` |
| `plugin/` | Claude Code plugin: `scripts/board.py`, skills, commands, SessionStart hook, status line |
| `.claude-plugin/marketplace.json` | Marketplace entry that points at `./plugin` |
| `extras/claude-statusline.sh` | Two-row Claude Code status line |
| `spec/` | `board.md` contract, `providers.md` research, JSON fixtures used by both test suites |
| `docs/` | Static marketing site |

## Conventions

- `board.json` is the only interface between writers (apps) and readers (widgets, plugin, status line). Change `spec/board.md` and the fixtures first, then every client. Readers must skip unknown keys and vendors.
- Read-only toward vendors: never refresh, store, log or write back a token. Refreshing from a second process rotates the grant and signs the real tool out.
- Plugin Python stays standard library only.
- Keep `CHANGELOG.md` `[Unreleased]` current. Plugin and marketplace versions are set in both manifests.

## Verify a change

1. Plugin or spec change: plugin tests and manifest check.
2. Windows change: the core tests.
3. macOS change: the unsigned build. Run the app to check the menu bar and dashboard.

## Deploy risk

Nothing deploys automatically. CI (`.github/workflows/ci.yml`) builds and tests on push and PR. Users install the plugin from `main` through `/plugin marketplace add patrickking67/ai-usage-widgets`, so a merge to `main` reaches plugin users on their next update.
