# AGENTS.md

TokenMeter (repo `ai-usage-widgets`) shows AI coding plan limits for Claude, Codex, GitHub Copilot, Cursor and Grok: a macOS menu bar app with WidgetKit widgets, a Windows PowerShell and WPF tray app, and a Claude Code plugin. Start at `README.md`. The data contract every client shares is `spec/board.md`.

## Stack

- macOS: Swift 5 and SwiftUI, macOS 14+, WidgetKit. `apps/macos/project.yml` is the XcodeGen source; the `.xcodeproj` is generated and gitignored.
- Windows: PowerShell 5.1 or 7 and WPF. No modules, no build step.
- Plugin: Python 3, standard library only, plus small shell scripts.
- Static page: one hand-written `docs/index.html`, not published anywhere.

## Layout

| Path | What it is |
| --- | --- |
| `apps/macos/App/` | Menu bar app, dashboard, settings, collector |
| `apps/macos/App/Providers/` | One `ProviderSource` per vendor lane; `ClaudeLive.swift` is the Claude endpoint |
| `apps/macos/Shared/` | Board model (`Usage.swift`), activity model, views shared with the widget |
| `apps/macos/Widget/` | WidgetKit extension (sandboxed, reads the board only) |
| `apps/macos/Tests/` | XCTest bundle, not hosted in the app: parsing, pace math, VoiceOver text |
| `apps/windows/` | `TokenMeter.Core.psm1` (logic), `TokenMeter.ps1` (UI), install scripts, `tests/Core.Tests.ps1` |
| `plugin/` | Claude Code plugin: `scripts/board.py`, skills, commands, SessionStart hook, tests |
| `.claude-plugin/marketplace.json` | Marketplace entry pointing at `./plugin` |
| `extras/claude-statusline.sh` | Two-row Claude Code status line (needs `jq`) |
| `spec/` | `board.md` contract, `providers.md` research, `fixtures/` shared by all test suites |
| `docs/` | Static product page and screenshots |
| `scripts/check.sh` | The one check command |

## Commands

| Task | Command |
| --- | --- |
| Everything CI runs | `scripts/check.sh` |
| Same, without Xcode | `CHECK_SKIP_XCODE=1 scripts/check.sh` |
| Plugin tests | `python3 -m unittest discover -s plugin/tests` |
| Windows core tests | `pwsh -NoProfile -File apps/windows/tests/Core.Tests.ps1` (exit code = failures) |
| macOS unit tests | `cd apps/macos && xcodegen generate && xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` |
| macOS build, unsigned | `cd apps/macos && xcodegen generate && xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build` |
| Preview the page | `python3 -m http.server 4116 --bind 127.0.0.1 --directory docs` (also in `.claude/launch.json`) |

Tools: `brew install xcodegen shellcheck actionlint powershell`, plus Xcode. Lint is shellcheck, actionlint and a PowerShell parse check; there is no Swift formatter or linter configured.

## Conventions

- `board.json` is the only interface between writers (apps) and readers (widgets, plugin, status line). Change `spec/board.md` and the fixtures first, then every client. Readers must skip unknown keys and vendors.
- Parsing lives in `nonisolated static` decode functions so `apps/macos/Tests` can call them with fixtures. Add a fixture and a test for any new or changed response shape. Synthetic fixtures use made-up values only.
- Plugin Python stays standard library only.
- Keep `CHANGELOG.md` `[Unreleased]` current. Plugin and marketplace versions live in both manifests.
- Conventional Commits; branches `feat/`, `fix/`, `docs/`, `chore/`. No em dashes or emojis in new text.

## Safety rules

- Read-only toward vendors. Never refresh, rotate, store, log or write back a token or cookie. An expired token waits for the vendor's own tool to renew it. A token goes into one request header to that vendor's own endpoint and nowhere else.
- Never send a credential to a new host. Adding an endpoint means documenting it in `spec/providers.md`, `README.md` and `SECURITY.md` in the same change.
- Copilot goes through `gh`; never read the GitHub token directly. Cursor's database is opened read-only.
- Logs carry status codes and short error text only. Never interpolate a token, cookie, user ID or response body that could carry one.
- Tests never touch the network, the Keychain or the real home directory. The macOS test bundle is deliberately not hosted in the app, so it never starts the collector.
- No real account names, org names, tokens or usage data in fixtures, screenshots or docs.

## Do not touch

- `apps/macos/Config/Local.xcconfig` (per-developer signing team, gitignored) and the generated `TokenMeter.xcodeproj`.
- `docs/img/` screenshots unless re-rendered from the anonymised demo board.
- GitHub settings, secrets and branch protection.

## Ship

1. Branch from `main`, make one logical change per commit.
2. `scripts/check.sh` passes.
3. Update `CHANGELOG.md` and, for a board change, `spec/board.md`.
4. Open a PR. Nothing deploys; a merge to `main` reaches plugin users on their next update.

## Definition of done

`scripts/check.sh` passes locally and in CI; new parsing has fixtures and tests; docs match the code; for UI changes, the app was run and the change checked by eye and with VoiceOver where it matters.
