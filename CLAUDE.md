@AGENTS.md

## Claude Code notes

- Work in a worktree under `.worktrees/` or `.claude/worktrees/`. `.worktreeinclude` copies `apps/macos/Config/Local.xcconfig` (a signing team ID, not a credential) when it exists.
- Running the macOS app reads your real Claude, Codex, Cursor and Grok sign-ins and calls their endpoints. Use the unit tests for parsing changes; launch the app only to check UI.
