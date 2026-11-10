# Contributing

## Setup

```bash
brew install xcodegen shellcheck actionlint powershell
git clone git@github.com:patrickking67/tokenmeter.git
cd tokenmeter
scripts/check.sh
```

Xcode is needed for the macOS steps. Without it, `CHECK_SKIP_XCODE=1 scripts/check.sh` runs the rest. To build the widgets with your own signing team, put `DEVELOPMENT_TEAM = YOURTEAMID` in `apps/macos/Config/Local.xcconfig` (gitignored).

## Branches and commits

- Branch from `main`: `feat/…`, `fix/…`, `docs/…` or `chore/…`.
- [Conventional Commits](https://www.conventionalcommits.org/): `feat(macos): …`, `fix(windows): …`, `docs: …`.
- One logical change per commit, each one passing `scripts/check.sh`.

## Changing what TokenMeter reads

- A new response shape needs a fixture in `spec/fixtures` (made-up values only) and a test.
- A new endpoint or credential source needs `spec/providers.md`, the data sources table in `README.md` and `SECURITY.md` updated in the same PR.
- Credentials are read-only: never refresh, store, log or write back a token.
- A board change starts in `spec/board.md`, then every client.

## Pull request checklist

- [ ] `scripts/check.sh` passes
- [ ] Tests added or updated for changed behaviour
- [ ] `CHANGELOG.md` `[Unreleased]` updated for user-facing changes
- [ ] Docs match the code
- [ ] No tokens, cookies, account names or real usage data anywhere in the diff

CI runs `scripts/check.sh` on macOS and the Windows core tests on Windows for every push and pull request.
