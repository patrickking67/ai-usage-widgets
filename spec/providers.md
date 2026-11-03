# Providers: Cursor, Grok, GitHub Copilot, Microsoft 365 Copilot

How TokenMeter reads plan limits for vendors beyond Claude Code and Codex.
Research date: 2026-09-27. None of these tools were installed on the
authoring machine, so **nothing here has been checked against a real
account**. Every lane below ships with `experimental: true` until someone
records a fixture from a real account.

Evidence labels used throughout:

- **[doc]**: the vendor's own documentation or open-source code.
- **[multi]**: two or more independent, maintained open-source readers agree.
- **[single]**: only one third-party source says so.
- **[inferred]**: our own reasoning. Verify before relying on it.

Rules that apply to every lane:

- Open credential stores **read-only**. For SQLite, use `SQLITE_OPEN_READONLY`.
- **Never refresh a token, and never write one back.** A refresh rotates the
  vendor's refresh token and can sign the user out of the real tool. When a
  token has expired, report the lane as stale or signed out.
- Never log, print, persist or put on the board any token, cookie or user ID.
  Keep them in memory for the length of one request.
- Send requests only to the hosts listed in this document.

---

## Cursor

### Token location

| OS | Store | Key | Evidence |
| --- | --- | --- | --- |
| macOS | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (SQLite, WAL) | table `ItemTable`, `key = 'cursorAuth/accessToken'`. Related keys: `cursorAuth/refreshToken`, `cursorAuth/cachedEmail`, `cursorAuth/stripeMembershipType` (plan hint, e.g. `free`, `pro`), `cursorAuth/stripeMembershipAuthId` | [multi] CodexBar, OpenUsage, tmux-og |
| Windows | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` | same keys | [single], and it follows the standard VS Code layout |
| Linux | `$XDG_CONFIG_HOME/Cursor/User/globalStorage/state.vscdb` (default `~/.config/...`) | same keys | [single] CodexBar |
| macOS, `cursor-agent` CLI | Keychain generic passwords, services `cursor-access-token` and `cursor-refresh-token` (account `cursor-user`). Also `~/.cursor/cli-config.json` → `authInfo.authId` / `authInfo.userId` | — | [multi] OpenUsage, tmux-og |

- The value is a JWT. `exp` gives the expiry (about 60 days per [single]).
  The user ID is the part of the `sub` claim after the last `|`.
- The column value can be TEXT or a BLOB. A BLOB may be UTF-8 or UTF-16LE;
  decode both ([doc] CodexBar `CursorAppAuth.swift`).
- **Read-only safe: yes.** Open with `SQLITE_OPEN_READONLY` and a short busy
  timeout. Use `?immutable=1` only when the `-wal` and `-shm` files are both
  missing, because otherwise it skips live data. OpenUsage writes refreshed
  tokens back into `state.vscdb`. **Do not do that.**
- Skip the token when fewer than 60 seconds remain before `exp`.

### Endpoint

**Primary: `GET https://cursor.com/api/usage-summary`** [multi]

- `Cookie: WorkosCursorSessionToken=<userId>%3A%3A<accessToken>`. This is
  `<userId>::<jwt>`, URL-encoded.
- `Accept: application/json`.
- A bearer header gets **401**; this endpoint accepts the cookie only
  [single, tmux-og #778].

Response shape. Money is in **USD cents** and percentages are 0–100
([doc] CodexBar models):

```jsonc
{
  "billingCycleStart": "2026-09-01T00:00:00.000Z",   // ISO-8601; accept epoch-ms strings too
  "billingCycleEnd":   "2026-10-01T00:00:00.000Z",
  "membershipType": "pro",            // free | pro | pro_plus | ultra | business/team | enterprise
  "limitType": "user",                // "team" on team seats
  "isUnlimited": false,
  "individualUsage": {
    "plan": { "enabled": true, "used": 1520, "limit": 2000, "remaining": 480,
              "breakdown": { "included": 2000, "bonus": 0, "total": 1520 },
              "autoPercentUsed": 12.0,    // "Cursor Models" pool
              "apiPercentUsed": 64.0,     // "Other Models" pool
              "totalPercentUsed": 38.0 },
    "onDemand": { "enabled": true, "used": 350, "limit": 5000, "remaining": 4650 },
    "overall":  { "enabled": true, "used": 6907, "limit": 45000, "remaining": 38093 } // team or enterprise seats only
  },
  "teamUsage": { "onDemand": {...}, "pooled": { "used": ..., "limit": ..., "remaining": ... } }
}
```

Percent fields are already in percent units: `0.36` means 0.36%, not 36%.
On free plans, `used` and `limit` can be 0 while the allowance shows up in
`breakdown.bonus` [single].

**Optional endpoints.** All use the same cookie. [doc] means CodexBar's
source code.

- `GET https://cursor.com/api/auth/me` returns `sub`, `email` and `name`. Use
  it for the `account` label. [doc]
- `GET https://cursor.com/api/usage?user=<userId>` is the older request-count
  endpoint. It returns `gpt-4.numRequests`, `numRequestsTotal`,
  `maxRequestUsage` and `startOfMonth`. Use it only for request-based
  enterprise plans. [multi]
- `POST https://cursor.com/api/dashboard/get-sand-usage-status` needs
  `Origin: https://cursor.com` and body `{}`. It covers Cursor's separate
  weekly "Grok Bot" allowance and returns `usagePercent`,
  `currentPeriodStart`, `nextResetTimestampUtc`, `hasNonZeroIncludedLimit`
  and `includedLimitZero`. [multi] CodexBar and OpenUsage
- `GET https://cursor.com/api/dashboard/export-usage-events-csv?startDate=<ms>&endDate=<ms>&strategy=tokens`
  returns per-event tokens as CSV (see Local logs below). [multi]

**Alternative: Connect RPC with a bearer token** [single, OpenUsage]

- `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
- Headers: `Authorization: Bearer <accessToken>`,
  `Content-Type: application/json`, `Connect-Protocol-Version: 1`. Body: `{}`.
- Fields: `billingCycleStart` and `billingCycleEnd` (epoch ms);
  `planUsage.{totalSpend, limit, remaining, autoPercentUsed, apiPercentUsed, totalPercentUsed}`;
  `spendLimitUsage.{individualLimit, individualRemaining, pooledLimit, pooledRemaining, limitType}`.
- `GetPlanInfo` on the same service returns the plan name.
- Use this as the fallback when the cookie endpoint changes.

**Official, but team admins only:** the Admin API at `https://api.cursor.com`
([doc](https://cursor.com/docs/account/teams/admin-api)).

- Auth is HTTP Basic with the admin key as the username.
- Endpoints: `POST /teams/spend` and `POST /teams/daily-usage-data`.
- It does not cover a personal plan, so it is not suitable for this lane.

### Response mapping

| Board field | Source |
| --- | --- |
| `plan` | `membershipType`, title-cased (`pro_plus` → "Pro+"). Fallback: `cursorAuth/stripeMembershipType`. |
| `account` | `/api/auth/me` → `email`, else `""` |
| Meter `"Monthly"` `used` | `individualUsage.plan.totalPercentUsed`. If absent: `plan.used / plan.limit × 100`. Then `overall.used / overall.limit`. Then `teamUsage.pooled`. When `isUnlimited`, emit no meter. |
| `"Monthly"` `resetsAt` | `billingCycleEnd` → unix seconds |
| `"Monthly"` `windowSeconds` | `billingCycleEnd − billingCycleStart` (about 2.6M) |
| Optional meters | `"Monthly · Cursor models"` = `autoPercentUsed`; `"Monthly · Other models"` = `apiPercentUsed`. Same reset and window as `"Monthly"`. |
| Optional `"Weekly · Grok Bot"` | `usagePercent`, `resetsAt = nextResetTimestampUtc`, `windowSeconds = next − currentPeriodStart`. Emit it only when an included limit exists. |
| `extra` | `{used: onDemand.used/100, limit: onDemand.limit/100}`. Use `teamUsage.onDemand` when the individual block is missing. |
| `updatedAt` | time of the fetch |

### Plan model

Since mid-2025, plans are **usage-based dollar pools, not request counts**
([doc](https://cursor.com/docs/account/pricing)):

- Pro ($20), Pro+ ($60) and Ultra ($200) each include two pools that reset
  with the **monthly billing cycle**. "Cursor Models" covers Auto, Composer
  and Grok variants. "Other Models" is billed at third-party API rates.
- Past the allowance, pay-as-you-go "on-demand" spend applies, up to a
  user-set limit.

**Show one monthly % bar with its reset date, plus `extra` for on-demand
spend.** There is no 5-hour or weekly window, apart from the optional Grok
Bot meter.

### Local logs

Cursor writes **no documented local token log** [inferred; no reader found
one]. Chat and composer data in `state.vscdb` (`cursorDiskKV`) is not a
billing record.

For the activity chart, the realistic source is the network CSV export:

- `GET https://cursor.com/api/dashboard/export-usage-events-csv?startDate=<ms>&endDate=<ms>&strategy=tokens`
  with the same cookie. Used by tokscale, OpenUsage, CodexBar and others.
- Columns include date, kind, model, input with and without cache write,
  cache read, output, total tokens and cost. The column order changes
  between versions, so parse by header name.
- It is not local, so fetch it at most every 15 minutes.
- `board.md` currently fills activity from local logs only, so adding
  `cursor` to `activity.days` means accepting a network-sourced series.
  Decide that before building it.

### Confidence & sources

**Cursor overall: medium-high.**

- Token location, cookie format and the `usage-summary` shape agree across
  several maintained readers [multi].
- Cursor does not document the endpoint. It is an internal dashboard API and
  can change without notice.
- Windows path: medium.

Sources:

- [CodexBar docs/cursor.md](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md), plus source `Sources/CodexBarCore/Providers/Cursor/{CursorAppAuth,CursorStatusProbe,CursorStatusProbe+UsageSummary,CursorSandUsage,CursorLocalCSVReader}.swift`
- [OpenUsage docs/providers/cursor.md](https://github.com/robinebers/openusage/blob/main/docs/providers/cursor.md), plus `Sources/OpenUsage/Providers/Cursor/{CursorAuthStore,CursorUsageClient,CursorUsageMapper}.swift`
- [tmux-og #778](https://github.com/noamsto/tmux-og/issues/778) (cookie-only auth, response examples)
- [codeburn #1546](https://github.com/getagentseal/codeburn/issues/1546) (enterprise shape)
- [Cursor pricing docs](https://cursor.com/docs/account/pricing) and [Admin API](https://cursor.com/docs/account/teams/admin-api)

### Recommended implementation

1. Read `cursorAuth/accessToken` read-only. Decode the JWT locally to get
   `sub` → userId and to check `exp`. If it has expired, report the lane as
   signed out and do not refresh.
2. `GET /api/usage-summary` with the cookie. In parallel, and optional, call
   `/api/auth/me` and `get-sand-usage-status`.
3. On a 401 or 403, report the lane as signed out. On a network failure,
   keep the last good board entry (it goes stale after 6 hours, per the
   board contract).
4. Poll every 5–10 minutes. Set `experimental: true` until a real fixture
   exists.
5. Store fixtures in `fixtures/cursor-usage-summary-*.json`. Anonymise
   `sub` and `email` before committing.

---

## Grok (xAI)

There are two separate products:

1. **Grok Build**: the official xAI coding CLI, `grok`.
   - Repo: [xai-org/grok-build](https://github.com/xai-org/grok-build), Apache-2.0,
     v1.0 on 2026-08-07.
   - Draws on the SuperGrok / X Premium+ subscription's shared **weekly**
     credit pool. **This is the "your plan limits" lane.**
   - The community `superagent-ai/grok-cli` only uses an API key and has no
     plan limits. Ignore it.
2. **xAI API**: pay-per-token API keys from console.x.ai. Spend there is
   dollars and is only visible through the Management API. At most this is
   an optional `extra` (spend), not a plan meter.

### Token location

| OS | Path | Evidence |
| --- | --- | --- |
| macOS / Linux | `$GROK_HOME/auth.json`, default `~/.grok/auth.json` | [doc] official user guide `02-authentication.md`, `xai-dirs` |
| Windows | `%USERPROFILE%\.grok\auth.json`. Home comes from `USERPROFILE` first. `$GROK_HOME` overrides it. | [doc] `crates/codegen/xai-dirs/src/lib.rs` |

- `auth.json` is a map from scope key to credential.
- Prefer keys starting with `https://auth.x.ai::` (SuperGrok OIDC). Fall back
  to `https://accounts.x.ai/sign-in` (legacy).
- Also present: `xai::api_key` (plain API key). **Ignore it**: it is not a
  subscription credential.
- Each entry has these fields ([doc] `xai-grok-login/src/model.rs`):
  - `key`: the bearer token
  - `refresh_token`, `expires_at`, `auth_mode`, `user_id`, `email`
  - `team_id`, `team_name`, `principal_type`, `first_name` / `last_name`
- The file has mode 0600. `grok` refreshes the token itself. Credentials
  without a server expiry fall back to 30 days; CodexBar observes about 7 days.
- **Read-only safe: yes.** It is a plain JSON file read. Never write it and
  never refresh it; `grok` holds a file lock while it rotates tokens.

### Endpoint

**Primary: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`**

This is what `grok` itself calls for `/usage` ([doc] official
`xai-grok-shell/src/extensions/billing.rs`). Headers the official client
sends:

- `Authorization: Bearer <key>`
- `X-XAI-Token-Auth: xai-grok-cli`. The value is from CodexBar [single]; the
  official source reads it from `GrokComConfig::default().token_header`.
- `x-userid: <user_id>`
- `x-grok-client-version: <semver>`. The proxy has a version gate, so send a
  current `grok` version string.
- `Accept: application/json`

The base URL can be overridden with `GROK_CLI_CHAT_PROXY_BASE_URL` (used by
enterprise OIDC). Honour it only when the user configures it.

Response: proto3 JSON. Zero scalars are **omitted**, so a missing `val` means
0. Cents are `{ "val": <int> }` ([doc] `BillingConfig`):

```jsonc
{
  "config": {
    "creditUsagePercent": 23.5,                      // 0–100; preferred
    "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
                       "start": "2026-09-22T17:00:00Z", "end": "2026-09-29T17:00:00Z" },
    "onDemandCap":  { "val": 5000 }, "onDemandUsed": { "val": 0 },
    "prepaidBalance": { "val": 1200 },
    "isUnifiedBillingUser": true,
    "productUsage": [ { "product": "GrokBuild", "usagePercent": 20.0 }, { "product": "GrokChat", "usagePercent": 3.5 } ],
    // deprecated monthly shape, still sent to some accounts:
    "monthlyLimit": { "val": 99900 }, "used": { "val": 12345 },
    "billingPeriodStart": "...", "billingPeriodEnd": "...",
    "history": [ { "billingCycle": {"year":2026,"month":8}, "includedUsed": {...}, "onDemandUsed": {...}, "totalUsed": {...} } ]
  },
  "subscriptionTier": "SuperGrok"                    // may be absent from the raw proxy reply
}
```

**Plan name:** `GET https://cli-chat-proxy.grok.com/v1/settings` with the
same headers returns `subscription_tier_display`, e.g. "SuperGrok" or
"SuperGrok Heavy" [single, CodexBar].

**Fallbacks, not recommended:**

- `grok agent stdio` with the JSON-RPC `x.ai/billing` method.
  - It makes the official CLI run the same request, so no token handling is
    needed in TokenMeter.
  - CodexBar reports `-32601 Method not found` on agent-stdio in grok 0.1.210;
    official source now wires it in `acp_agent.rs`.
  - Spawning a subprocess per poll is heavy. Worth trying first where
    available.
- `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
  (gRPC-web with browser cookies). It now needs a browser-held key-exchange
  proof. **Not feasible.**

### Response mapping

| Board field | Source |
| --- | --- |
| `plan` | `/v1/settings` → `subscription_tier_display`. Otherwise `subscriptionTier`. Otherwise "SuperGrok". |
| `account` | `auth.json` → `team_name` for team principals, else `"Personal"`. Never the email. |
| Meter label | `"Weekly"` when `currentPeriod.type` = `USAGE_PERIOD_TYPE_WEEKLY`, `"Monthly"` for monthly |
| `used` | `config.creditUsagePercent`. Legacy fallback: `used.val / monthlyLimit.val × 100`. If neither exists, emit **no** meter; unknown is not 0%. |
| `resetsAt` | `currentPeriod.end`, else `billingPeriodEnd` → unix seconds |
| `windowSeconds` | `end − start` from the same period object. If the period is weekly and the start is missing: 604800. |
| `extra` | `{used: onDemandUsed.val/100, limit: onDemandCap.val/100}` when `onDemandCap > 0` |
| Product split | `productUsage` is a share of the **same** pool. Show it as detail, never as a separate meter. |

### Plan model

Since June 2026, paid Grok plans draw on **one shared weekly credit pool**
across Chat, Imagine, Voice, Build and API-in-app. It resets at an
account-specific time shown in Settings → Usage, not at midnight or on
Monday ([doc] [Grok FAQ](https://docs.x.ai/grok/faq); xAI on X).

- Plans: SuperGrok Lite ($10), SuperGrok ($30), SuperGrok Plus ($100) and
  Heavy.
- When the pool runs out, paid features pause until the reset, unless the
  user has Extra Usage Credits (prepaid, from $5).
- The legacy monthly `monthlyLimit` shape is still possible.

**Show a % bar with a reset date, weekly for most accounts.** Put on-demand
or prepaid spend in `extra`.

### Local logs

- `~/.grok/sessions/<url-encoded-cwd>/<session-id>/signals.json` [doc,
  official `17-sessions.md` and `session/signals.rs`].
  - Per-session fields: `turnCount`, `contextTokensUsed`,
    `contextWindowTokens`, `totalTokensBeforeCompaction`, `modelsUsed[]`,
    `primaryModelId`.
  - These are **context snapshots, not billed totals**. Summing them gives a
    rough token series only.
- `updates.jsonl` in the same directory is the ACP update stream.
  - Per-turn usage (`inputTokens`, `outputTokens`, `numTurns`,
    `costUsdTicks`, `modelUsage.<model>.*`) is persisted somewhere under the
    session. The official CLI exposes it as `grok usage <session-id> [turn]`,
    which prints JSON with `sessionId`, `updatedAt`, `session` and `turns`.
  - `costUsdTicks / 1e10` gives dollars.
  - The exact on-disk record is [inferred] to be in `updates.jsonl`. Prefer
    shelling out to `grok usage` over parsing private files.
- `~/.grok/logs/unified.jsonl`: every `x.ai/billing` call made by the running
  TUI logs `"billing: fetched credits config"` with the full `config`
  (percent, period, tier), without history.
  - [doc] source comment in `billing.rs`.
  - This is a **zero-network, read-only** way to get the latest limit when
  `grok` is in use. It goes stale when `grok` is not running; use the
  entry's timestamp as `updatedAt`.
  - Not verified on disk.

### xAI API (API-key spend): the Management API

- Base URL `https://management-api.x.ai`, header
  `Authorization: Bearer <management key>` ([doc](https://docs.x.ai/developers/management-api-guide)).
- The management key is separate from API keys. The user must create one in
  console.x.ai → Settings → Management Keys, and supply it and the `team_id`.
- Endpoints ([doc](https://docs.x.ai/developers/rest-api-reference/management/billing)).
  All amounts are USD cents as strings.
  - `GET /v1/billing/teams/{team_id}/postpaid/invoice/preview` →
    `coreInvoice.amountAfterVat`, `effectiveSpendingLimit`,
    `billingCycle {year, month}`
  - `GET /v1/billing/teams/{team_id}/postpaid/spending-limits` →
    `spendingLimits.effectiveHardSl.val` and `softSl.val`
  - `GET /v1/billing/teams/{team_id}/prepaid/balance` → `total.val`
  - `POST /v1/billing/teams/{team_id}/usage`: time-series analytics
    (`timeUnit`, `values:[{name:"usd"}]`, `groupBy`)
- This is **realistic only as an opt-in `extra`** (monthly API spend against
  the spending limit). It needs a secret the user pastes in, which TokenMeter
  should keep in the OS keychain and never on the board. It is not a plan
  limit.

### Confidence & sources

**Grok overall: medium.**

- The token path, proxy URL, response structure and local files come from
  xAI's own open-source CLI [doc].
- The exact `X-XAI-Token-Auth` value and `/v1/settings` come from CodexBar
  only [single].
- `creditUsagePercent` is sometimes omitted (proto3). CodexBar documents
  period-only answers, so plan for an "unknown" state.
- The proxy is internal, and xAI can version-gate or change it.

Sources:

- [xai-org/grok-build](https://github.com/xai-org/grok-build): `crates/codegen/xai-grok-shell/src/extensions/{billing,usage}.rs`, `xai-grok-login/src/model.rs`, `xai-dirs/src/lib.rs`, `xai-grok-shell/src/session/signals.rs`, user guide `02-authentication.md`, `17-sessions.md`, `04-slash-commands.md`
- [CodexBar docs/grok.md](https://github.com/steipete/CodexBar/blob/main/docs/grok.md) and `Providers/Grok/GrokCreditsProxyFetcher.swift`
- [Grok FAQ](https://docs.x.ai/grok/faq); [Management API billing](https://docs.x.ai/developers/rest-api-reference/management/billing)

### Recommended implementation

1. Read `auth.json` read-only and pick the `https://auth.x.ai::*` entry. If
   `expires_at` has passed, report the lane as signed out and tell the user
   to run `grok login`.
2. Zero-network first: tail `~/.grok/logs/unified.jsonl` for the newest
   `billing: fetched credits config` entry. If it is less than 10 minutes
   old, use it.
3. Otherwise `GET …/v1/billing?format=credits` with the headers above.
   Optionally call `/v1/settings` for the plan name, with a 2-second timeout.
4. Map the result as above. Leave out the meter when usage is unknown.
5. Treat the Management API as a separate, opt-in "xAI API spend" `extra`.
6. Set `experimental: true`. Store fixtures in `fixtures/grok-credits-*.json`.

---

## GitHub Copilot

**Note: `board.md` has no `copilot` vendor yet.** Adding one is a contract
change for all three clients. Until then, readers skip it as an unknown
vendor.

### Token location

`GET /copilot_internal/user` needs a GitHub OAuth user token (`gho_…`). The
places to find one:

| Source | macOS / Linux | Windows | Evidence |
| --- | --- | --- | --- |
| Copilot editor plugins (JetBrains, Neovim, copilot-language-server) | `~/.config/github-copilot/apps.json`; the key is `github.com:<appId>` and the value is `oauth_token`. Older plugins use `hosts.json`. | `%LOCALAPPDATA%\github-copilot\apps.json` | [multi] OpenUsage, codeburn |
| GitHub CLI (`gh auth login`) | `~/.config/gh/hosts.yml` → `oauth_token`, only with insecure storage. Default is the Keychain, service `gh:github.com` (go-keyring). | `%APPDATA%\GitHub CLI\hosts.yml`, or Windows Credential Manager (go-keyring) | [single] OpenUsage for gh. Windows paths [inferred] from gh's defaults. |
| VS Code | The GitHub session sits in VS Code's encrypted secret storage (Electron safeStorage, backed by the Keychain / DPAPI) | same | [inferred]. **Do not read it.** Decrypting it means going through the "Code Safe Storage" Keychain gate. It is not a read-only-friendly source. |

- The simplest portable option is to run `gh auth token` as a subprocess and
  keep its stdout in memory only. It prompts nothing when `gh` is already
  signed in.
- **Does the gh-CLI token work?**
  - OpenUsage reports that it does, and recommends `gh auth login` as the
    setup step [single].
  - VS Code itself sends its own GitHub session as `Bearer`
    ([doc] vscode `chatEntitlementService.ts`).
  - Treat the gh token as likely but unverified. Some Enterprise Managed
    User or SSO-enforced orgs may reject tokens from apps that have not been
    authorised.
- **Read-only safe: yes** for the file and `gh auth token`. Never store the
  token.

### Endpoint

`GET https://api.github.com/copilot_internal/user`. For GHE.com, use
`https://api.<enterpriseHost>/copilot_internal/user`. This endpoint is
**internal and undocumented**, but VS Code, OpenUsage, CodexBar,
oh-my-posh, Raycast and the Copilot SDK all use it [multi].

Headers, as used by OpenUsage and CodexBar:

- `Authorization: token <gho_…>`
- `Accept: application/json`
- `Editor-Version: vscode/1.96.2`
- `Editor-Plugin-Version: copilot-chat/0.26.7`
- `User-Agent: GitHubCopilotChat/0.26.7`
- `X-Github-Api-Version: 2025-04-01`

Response fields ([doc] vscode `src/vs/base/common/defaultAccount.ts`):

```jsonc
{
  "copilot_plan": "individual_pro", "access_type_sku": "...", "token_based_billing": true,
  "quota_reset_date": "2026-10-01", "quota_reset_date_utc": "2026-10-01T00:00:00Z",
  "limited_user_reset_date": "...",                          // Copilot Free
  "quota_snapshots": {
    "premium_interactions": { "percent_remaining": 72.5, "unlimited": false,
      "entitlement": 1500, "quota_remaining": 1087, "credits_used": 413,
      "overage_count": 0, "overage_permitted": true, "quota_reset_at": 1790812800 },
    "chat": { "unlimited": true, ... }, "completions": { "unlimited": true, ... }
  },
  "limited_user_quotas": { "chat": 40, "completions": 1800 },  // legacy Free shape
  "monthly_quotas":      { "chat": 50, "completions": 2000 }
}
```

The `-1` value in `entitlement` or `remaining` means unlimited [multi].

### Response mapping

| Board field | Source |
| --- | --- |
| `plan` | `copilot_plan`, mapped to a label (Free, Pro, Pro+, Business, Enterprise) |
| Meter `"Monthly"` `used` | `100 − quota_snapshots.premium_interactions.percent_remaining`. Skip it when `unlimited`, when entitlement is `-1`, or when **entitlement is 0**, which is the org-seat placeholder. |
| `resetsAt` | `quota_reset_date_utc`, else `quota_reset_date` (00:00 UTC), else `premium_interactions.quota_reset_at` |
| `windowSeconds` | From 00:00 UTC on the 1st of the previous month to `resetsAt`. The AI-credit allowance resets on the 1st, 00:00 UTC, whatever the billing date. |
| Free plan | Meters `"Monthly · Chat"` and `"Monthly · Completions"` from those snapshots, or from `limited_user_quotas` / `monthly_quotas` |
| `extra` | [inferred] `{used: overage_count × $0.01}` when `overage_permitted`, since 1 AI credit = $0.01. No limit is exposed; the budget is only on the github.com web page. |
| Org-managed seat | No personal percentage exists. Show `credits_used` as detail text only. |

### Plan model

From **2026-06-01**, Copilot bills in **AI credits** (1 credit = $0.01,
token-based) ([doc](https://docs.github.com/copilot/concepts/billing/usage-based-billing-for-individuals)):

- Pro includes 1,500 credits a month and Pro+ includes 7,000.
- The allowance resets **monthly at 00:00 UTC on the 1st**.
- Code completions and next-edit suggestions are unlimited on paid plans.
- Free plans get 2,000 completions and a limited chat allowance.
- Annual Pro and Pro+ subscribers stay on the legacy premium-request quota
  until their plan renews. It is the same `premium_interactions` bucket.
- Past the allowance, a user-set budget buys more at $0.01 per credit.

**Show one monthly % bar with its reset date.** Business and Enterprise seats
usually have no per-seat bar.

### Local logs

These are VS Code agent mode and Copilot Chat logs. The paths use the VS Code
`User` directory: `~/Library/Application Support/Code/User`,
`%APPDATA%\Code\User` or `~/.config/Code/User`, plus `Code - Insiders`,
VSCodium and `profiles/<id>/`. All evidence is [multi]: codeburn, deja-vu,
agentsview, TokenTracker and VS Code issue #308730.

| File | Format | Per-request fields |
| --- | --- | --- |
| `workspaceStorage/<hash>/chatSessions/<id>.json` (before VS Code 1.109, Feb 2026) | whole-file JSON: `{sessionId, creationDate, lastMessageDate, requests[]}` | `requestId`, `timestamp` (ms), `modelId`, `result.metadata.resolvedModel` / `model`, `result.timings`, and sometimes `promptTokens`, `completionTokens` / `outputTokens` |
| `workspaceStorage/<hash>/chatSessions/<id>.jsonl` (1.109+) | a mutation journal. `kind` 0 = initial root, 1 = set at path `k`, 2 = push (optional truncate index), 3 = delete. Replay it into the same object. Compaction rewrites the file, so re-parse it fully every time. | same as the row above. Token counts are **often missing** (cancelled requests, some agent turns). |
| `globalStorage/emptyWindowChatSessions/<id>.{json,jsonl}` (also `transferredChatSessions/`) | same | same |
| `workspaceStorage/<hash>/GitHub.copilot-chat/transcripts/<id>.jsonl` (newer extension) | typed events: `session.start`, `user.message`, `assistant.message`, `assistant.turn_start` / `turn_end`, `tool.execution_*` | mostly output side only |
| `globalStorage/github.copilot-chat/agent-traces.db` (SQLite) | OTel spans. **Off by default**: needs `github.copilot.chat.otel.enabled` and `github.copilot.chat.otel.dbSpanExporter.enabled` | full input, output, cache-read and cache-write per LLM call. The only complete local token source. |
| Copilot CLI: `~/.copilot/session-store.db` → `assistant_usage_events`, and `~/.copilot/session-state/*/events.jsonl` | SQLite, JSONL | per request: model, input (including cache), cache read and write, output, timestamps |

Conclusions:

- Model and timestamp are reliable.
- Token counts are **partial** unless the OTel database is enabled.
- Dedupe `.json` and `.jsonl` copies of the same session by `sessionId`.
- If the OTel database is present, prefer it and skip the journals; their IDs
  do not match OTel turn IDs.

### Confidence & sources

**Copilot overall: medium-high for the quota; medium for local tokens.**

- The endpoint and fields are confirmed by VS Code's own source and several
  readers.
- Whether the gh-CLI token works comes from one source.
- The billing model is GitHub's own documentation.

Sources:

- [VS Code defaultAccount.ts](https://github.com/microsoft/vscode/blob/main/src/vs/base/common/defaultAccount.ts) and `chatEntitlementService.ts`
- [OpenUsage docs/providers/copilot.md](https://github.com/robinebers/openusage/blob/main/docs/providers/copilot.md) and `Providers/Copilot/*`
- [CodexBar docs/copilot.md](https://github.com/steipete/CodexBar/blob/main/docs/copilot.md)
- [codeburn docs/providers/copilot.md](https://github.com/getagentseal/codeburn/blob/main/docs/providers/copilot.md) and `src/providers/copilot.ts`
- [deja-vu copilot-chat registry](https://github.com/vshulcz/deja-vu/blob/main/docs/registry/copilot-chat.md)
- [GitHub Docs: usage-based billing for individuals](https://docs.github.com/copilot/concepts/billing/usage-based-billing-for-individuals)

### Recommended implementation

1. Get a token: read `apps.json` or `hosts.json` first, then run
   `gh auth token`. Never touch VS Code's secret storage.
2. `GET copilot_internal/user` and map it as above. On a 401 or 403, report
   the lane as signed out.
3. For activity, replay `chatSessions` journals and the Copilot CLI
   `session-store.db`. Label token totals "partial" unless `agent-traces.db`
   exists.
4. Add `"copilot"` to the board's vendor enum in `board.md` as a separate,
   deliberate change.

---

## Microsoft 365 Copilot

### Verdict: there is no per-user limit source for an individual. Do not build a limits lane.

| Question | Finding |
| --- | --- |
| Published per-user quota? | None. Licensed users get "priority access" with no published numeric limit. [doc/inferred] |
| Per-user usage API for **yourself**? | **No.** `GET https://graph.microsoft.com/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D7')` needs `Reports.Read.All`. Even with delegated permission, the user must hold an Entra admin role such as Reports Reader, AI Administrator or Global Admin ([doc](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/api/admin-settings/reports/copilotreportroot-getmicrosoft365copilotusageuserdetail)). The v2 data has last-activity dates per app, prompts submitted and active days. It has no limits and no tokens, it covers licensed users only, and it is often pseudonymised. |
| Interaction export? | `GET /v1.0/copilot/users/{id}/interactionHistory/getAllEnterpriseInteractions` accepts **application permission only** (`AiEnterpriseInteraction.Read.All`). No delegated or self access. Content, not quotas. ([doc](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/api/ai-services/interaction-export/aiinteractionhistory-getallenterpriseinteractions)) |
| Unlicensed Copilot Chat | Only in the admin centre, Purview audit or the Office 365 Management Activity API. All admin-only. |
| Local logs | None documented. [inferred] |

**Feasible:** an optional "tenant admin" mode that shows *activity*
(prompts, active days) from the Graph report, for admins who sign in with an
Entra app. It is not a plan-limit meter and does not fit the `Meter` model.

**Not feasible:** any percentage used, reset or limit for an individual M365
Copilot user.

**Confidence: high.** Microsoft documents the permission requirements
explicitly.

---

## Summary

| Vendor | Limit source | Meter | Confidence |
| --- | --- | --- | --- |
| Cursor | `state.vscdb` token → `cursor.com/api/usage-summary` (cookie) | Monthly % + on-demand `extra` | medium-high (undocumented API) |
| Grok | `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing?format=credits`, or `~/.grok/logs/unified.jsonl` | Weekly % (sometimes monthly) + on-demand `extra` | medium |
| xAI API | Management API with a user-supplied management key | `extra` spend only | high (documented), opt-in |
| GitHub Copilot | editor or gh token → `api.github.com/copilot_internal/user` | Monthly % (AI credits) | medium-high |
| M365 Copilot | none for individuals | — | high that it is not feasible |
