# Security

## Supported versions

| Version | Supported |
| --- | --- |
| `main` and the latest release (1.x) | Yes |
| Anything older | No |

## Reporting a vulnerability

Report privately through GitHub: <https://github.com/patrickking67/tokenmeter/security/advisories/new>. Do not open a public issue, and do not include real tokens, cookies or auth files in the report.

You can expect an acknowledgement within 7 days and an assessment within 30 days. Fixes land on `main` and are noted in `CHANGELOG.md`.

## Scope

In scope: anything that could expose, persist, log or misuse a credential TokenMeter reads; requests to hosts other than those listed below; the macOS widget's sandbox; the Windows install scripts; the plugin and status line scripts.

Out of scope: the vendors' own services and endpoints, and issues that need an attacker who already controls the user's account or files.

## How TokenMeter handles credentials

TokenMeter has no server, account or telemetry. It reads sign-ins that other tools already keep on the machine, read-only, and puts each token in one request header to that vendor's own endpoint. It never refreshes, rotates, stores, logs or writes back a token. An expired token is skipped until the vendor's tool renews it.

| Lane | Credential source | Only host it is sent to |
| --- | --- | --- |
| Claude (macOS) | Keychain item `Claude Code-credentials`, read with `/usr/bin/security find-generic-password -w` | `api.anthropic.com` |
| Claude (Windows) | `%USERPROFILE%\.claude\.credentials.json` | `api.anthropic.com` |
| Codex (macOS) | `~/.codex/auth.json` (`access_token`, `account_id`) | `chatgpt.com` |
| GitHub Copilot | None: `gh api /copilot_internal/user` makes the request, so the token stays in `gh` | `api.github.com`, via `gh` |
| Cursor (macOS, beta) | `cursorAuth/accessToken` in Cursor's `state.vscdb`, opened read-only | `cursor.com` |
| Grok (macOS, beta) | Sign-in entry in `~/.grok/auth.json` | `cli-chat-proxy.grok.com` |

The Codex `id_token` and Cursor access token are also decoded locally for the plan name and user ID; those claims are not stored. Logs (the macOS unified log, and `tokenmeter.log` on Windows) carry status codes and short error text only. The macOS widget is sandboxed with read-only access to `~/.cache/tokenmeter/`, so it never sees a credential. Full field-level detail is in `spec/providers.md`.

## Release integrity

macOS releases are built only by `.github/workflows/release.yml` (or `scripts/release-macos.sh` on the maintainer's Mac), signed with the maintainer's Developer ID Application certificate, notarized by Apple and stapled. Each release publishes `SHA256SUMS` and a GitHub build provenance attestation (`gh attestation verify`). The signing certificate and the App Store Connect API key live only in the `release` environment's secrets, which need a reviewer's approval to use, and in a temporary keychain deleted at the end of the run. Workflows pin third-party actions to commit SHAs and default to read-only `contents` permission.
