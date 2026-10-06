# Quota: agent instructions

Native macOS menu bar app (Swift, AppKit + SwiftUI, SwiftPM) that shows remaining subscription usage for the Claude, Codex, Grok and Ollama Cloud accounts the user links. The Linux version is Quotax (github.com/turinglabsorg/quotax): keep behavior, data sources and copy in sync with it.

## Layout

- `Sources/QuotaCore`: models, parsers, fetchers, account linking, command/keychain helpers. No UI. Parsers must stay unit-testable with fixture JSON.
- `Sources/Quota`: the app (status item, popover, account store, link controller, CLI report, preview renderer).
- `Tests/QuotaCoreTests`: Swift Testing suites.
- `DESIGN.md`: design system. Read it before any UI change and update it when you add patterns.

## Commands

- Test: `scripts/test.sh` (adds the Swift Testing macro plugin path required by Command Line Tools). Live tests against the real CLIs and Keychain are skipped unless `QUOTA_LIVE_TESTS=1`.
- Build app bundle: `scripts/build-app.sh`; build and install into `~/Applications`: `scripts/build-app.sh --install`.
- End-to-end check without UI: `~/Applications/Quota.app/Contents/MacOS/Quota --print` (linked accounts, or detected CLI logins when none are linked). `QUOTA_DEBUG=1` logs failed HTTP responses, `QUOTA_DEBUG=verbose` logs every usage response body (never tokens).
- Render UI previews with sample data: `.build/debug/Quota --render-preview <dir>`. AppKit-backed controls (buttons, menus, spinners) render as placeholders there, except in `readme-*.png`, which use the `isStaticPreview` environment flag. Regenerate `docs/screenshots/readme-{light,dark}.png` from it after visible UI changes.
- Check a translation live: `build/Quota.app/Contents/MacOS/Quota --print -AppleLanguages '(it)'`.

## Toolchain gotcha

With the macOS 27 SDK, SwiftUI `@State` is a macro whose plugin is missing from Command Line Tools. Keep view state in `ObservableObject`s (see `PopoverRouter`) instead of `@State`.

## Accounts

The user decides which accounts are monitored; nothing is linked automatically. Accounts are stored (without secrets) in the `com.turinglabs.quota.shared` defaults suite.

- **Shared login** (`Account.Source.cli`): reuses the CLI's own session (Claude Keychain item `Claude Code-credentials`, `~/.codex` via the Codex CLI, `~/.grok/auth.json`, the `~/.ollama/id_ed25519` device key that `ollama signin` linked). Quota never refreshes or writes these tokens itself: refresh tokens rotate, so doing it would sign the CLI out. When the shared Claude token has expired, Quota briefly starts `claude` in a pseudo-terminal so the CLI renews its own token, then retries (one attempt at a time, 10-minute cooldown after a failure; see `SharedClaudeLogin`).
- **Linked by Quota** (`.managed`): isolated home at `~/Library/Application Support/Quota/Accounts/<provider>/<uuid>`, signed in through the official CLI in the browser:
  - Codex: `CODEX_HOME=<home> codex login`; usage via `codex app-server` with the same `CODEX_HOME`, so Codex refreshes its own token.
  - Grok: `GROK_HOME=<home> grok login --oauth` inside `script` (Grok expects a TTY); expired tokens are refreshed by running `grok models` with the same home.
  - Claude: `CLAUDE_CONFIG_DIR=<home> claude auth login --claudeai`; credentials live in the scoped Keychain item `Claude Code-credentials-<sha256(NFC(home))[:8]>`. The shared `Claude Code-credentials` item is snapshotted before login and restored afterwards so Claude Code keeps its account. Quota refreshes managed Claude tokens via `https://platform.claude.com/v1/oauth/token`.
  - Ollama Cloud (no CLI): Quota creates an Ed25519 key in `<home>/.ollama/id_ed25519` (OpenSSH format, mode 600), opens `https://ollama.com/connect?name=<hostname>&key=<base64url(authorized key)>` like `ollama signin` does, and polls `POST /api/me` until ollama.com reports the linked user (an unlinked key gets an empty user, not a 401).
- Unlinking a managed account runs the CLI logout (or deletes the scoped Keychain item, or calls `DELETE /api/user/keys/<key>` for Ollama Cloud) and removes its home.

## Data sources

Mirrors Orca (github.com/stablyai/orca, `src/main/rate-limits`, `src/main/*-accounts`):

- Claude: `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`.
- Codex: JSON-RPC `account/read` + `account/rateLimits/read` on `codex app-server`; fallback `GET https://chatgpt.com/backend-api/wham/usage` for the shared login when the CLI is missing.
- Grok: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with `X-XAI-Token-Auth: xai-grok-cli`, falling back to `/v1/billing` for monthly budgets. The API omits zero-valued fields: a missing `creditUsagePercent` means 0% only when the weekly `currentPeriod` matches `billingPeriodStart/End` and no field shows explicit zeros or spend (same rule as Orca).
- Ollama Cloud: `GET https://ollama.com/api/usage` (`limits.monthly.usage`, or legacy `limits.session`/`limits.weekly`, as fractions 0–1; no reset times) and `POST https://ollama.com/api/me` for email and plan. Requests are signed as in ollama/ollama `api/client.go`: `Authorization: <base64 public key blob>:<base64 Ed25519 signature of "<METHOD>,<path>?ts=<unix>">` with the same `ts` in the query (CryptoKit `Curve25519.Signing`). ollama.com answers with Go field names (`Email`, `Plan`), so keys are matched case-insensitively.

## Rules

- Never log, print or persist tokens. Keychain access goes through `/usr/bin/security` only.
- Never type or handle user passwords: sign-in always happens in the browser on the provider's page.
- Poll no more often than every 5 minutes; the usage endpoints rate-limit aggressive clients.
- Code, comments and docs in English.

## Localization

- English is the development language: user-facing strings are written in English in code (`String(localized:)` for computed strings, string literals in SwiftUI views).
- Every new user-facing string needs a translation in `Resources/it.lproj/Localizable.strings`. Keys use the compiler's format: `%@` for strings, `%lld` for integers.
- Never put a literal `%` inside a localized string; render percentages with `Text(verbatim:)`.
- Ternaries of string literals passed to `Text` are not localized: wrap each branch in `String(localized:)`.
