# The board: TokenMeter's data contract (v1)

Every TokenMeter client produces or consumes one JSON document, the **board**.
The macOS and Windows apps write it; their widgets and the Claude Code plugin
only read it. Keeping one document means three codebases cannot drift into
three products: if it is not on the board, no client shows it.

| Platform | Path |
| --- | --- |
| macOS | `~/.cache/tokenmeter/board.json` |
| Windows | `%LOCALAPPDATA%\TokenMeter\board.json` |
| Override | `$TOKENMETER_BOARD` (any platform) |

Writers replace the file atomically (write a sibling, then rename). Readers
must tolerate a missing file, unknown keys and unknown vendors.

## Shape

```jsonc
{
  "generatedAt": 1790566371.08,          // unix seconds
  "providers": [ Provider ],             // one per vendor with any data
  "activity": Activity | null            // absent until the first log scan
}
```

### Provider

| Key | Type | Meaning |
| --- | --- | --- |
| `vendor` | `"claude" \| "codex" \| "copilot" \| "cursor" \| "grok"` | Unknown values: skip the provider. |
| `account` | string | `"Personal"`, a workspace name, or `""` when unknown. |
| `plan` | string? | `"Max 20x"`, `"Business"`, `"Pro"`… |
| `meters` | `[Meter]` | Ordered shortest window first. May be empty. |
| `updatedAt` | number? | When the vendor last reported. Older than 6 h = **stale**: show the number dimmed, with its age. |
| `extra` | `{used, limit?}`? | Pay-as-you-go spend in dollars. |
| `note` | string? | One line for lanes with nothing to run out of, e.g. `"1,922 premium credits this month · no cap"`. Show under the account line. |
| `experimental` | bool? | Data source not verified on real accounts; say so in the UI. |
| `breakdown` | [{`label`, `percent`}]? | Share of the weekly window by surface, largest first (Claude only). |

### Meter

| Key | Type | Meaning |
| --- | --- | --- |
| `label` | string | `"Current"` (5 h), `"Weekly"`, `"Weekly · Opus"`, `"Monthly"`… Unique per provider. |
| `used` | number | Percent, 0–100. May exceed 100. |
| `resetsAt` | number? | Unix seconds. **Once passed, show 0% and "Fresh window"** — the stored number belongs to the old window. |
| `windowSeconds` | number | Window length; drives pace. |

**Pace.** With `e = elapsed / windowSeconds` (skip when `e < 0.08` or
`used < 1`): projected at reset = `used / e`; the limit is hit at
`now + (100 - used) / (used / (e × windowSeconds))` if that is before
`resetsAt`. Colour: red at ≥ 90% used or ≥ 130% projected, amber at ≥ 70% or
≥ 100%, otherwise the neutral accent.

### Activity

Built from the vendors' local logs; this machine only.

| Key | Meaning |
| --- | --- |
| `days` | Last 30 × `{day, claude, codex, copilot?, cursor?, grok?}` — local midnight, total tokens per vendor. Oldest first. Views default to the last 7; older boards may carry fewer entries. |
| `models` | `{vendor, model, tokens}` over 7 days, largest first. |
| `claude24h`, `codex24h`, `copilot24h?` | `{input, output, cacheRead, cacheWrite, requests}` over the last 24 h. |
| `drivers` | `{name, kind: "MCP"\|"Skill"\|"Subagent", calls, share}` — share of Claude tokens spent in session-hours the driver was active. Overlapping. |
| `subagentShare`, `longContextShare` | 0–1 shares of Claude tokens from subagents / sent with > 150k context. |

"Total tokens" = input + output + cache read + cache write, matching how the
vendors' own dashboards count.

## Sources

| Vendor | Limits | Activity |
| --- | --- | --- |
| Claude Code | `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's OAuth token (read only, never refreshed), headers `anthropic-beta: oauth-2025-04-20` and a `claude-code/*` User-Agent (without it the endpoint answers 429). | `~/.claude/projects/**/*.jsonl`: assistant lines' `message.usage`; one message spans several lines, so dedupe by `message.id`. |
| Codex | Newest `rate_limits` in `~/.codex/sessions/**/rollout-*.jsonl`. | `event_msg`/`token_count` → `info.last_token_usage`, skipping repeats (`total_token_usage.total_tokens` must grow). |
| GitHub Copilot | `GET https://api.github.com/copilot_internal/user` made by the `gh` CLI (`gh api /copilot_internal/user`) so the token never leaves gh. `quota_snapshots.premium_interactions`: metered seats → `"Premium requests"` meter, used = 100 − `percent_remaining`, reset `quota_reset_date`; `unlimited: true` → no meter, `note` with `credits_used`. | VS Code chat sessions: `Code/User/workspaceStorage/*/chatSessions/*.json[l]` and `globalStorage/emptyWindowChatSessions`. `.jsonl` = `kind: 0` snapshot + patches, so walk every object and merge by `requestId`; tokens = `promptTokens` + `completionTokens`. |
| Cursor, Grok | See `providers.md`. `experimental: true`. | — |
| Microsoft 365 Copilot | None: no per-user usage or limit source outside tenant-admin Graph reports. See `providers.md`. | — |

Fixtures: `fixtures/board.json` is a real board, anonymised.
`fixtures/typical.json` etc. are recorded Claude usage-endpoint responses;
`fixtures/codex-*.jsonl` are recorded Codex rollouts.
