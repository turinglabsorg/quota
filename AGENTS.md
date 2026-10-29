# Quota: agent instructions

Native macOS menu bar app (Swift, AppKit + SwiftUI, SwiftPM) that shows remaining subscription usage for the Claude, Codex, Grok, Ollama Cloud and Muse Code accounts the user links. The Linux version is Quotax (github.com/turinglabsorg/quotax): keep behavior, data sources and copy in sync with it. Muse Code on Quotax sums local session logs. Quota shows those same totals, with today's reset, under the subscription windows the accounts page shows.

## Layout

- `Sources/QuotaCore`: models, parsers, fetchers, account linking, command/keychain helpers. No UI. Parsers must stay unit-testable with fixture JSON.
- `Sources/Quota`: the app (status item, popover, account store, link controller, CLI report, preview renderer).
- `Sources/QuotaServer`: `quota-server`, a headless server that publishes the usage of the accounts linked on an always-on Mac for the iOS app (HTTP server on Network.framework, usage cache, paired devices, CLI commands).
- The iOS app and its widgets live in Quota iOS (github.com/turinglabsorg/quota-ios), which includes this repository as a git submodule and compiles `QuotaCore/{Models,Formatting,JSON,UsagePayload}.swift`, `Quota/ProviderGlyph.swift` and `Resources/*.lproj` from it. Changes to those files reach the iOS app when quota-ios bumps the submodule.
- `Tests/QuotaCoreTests`, `Tests/QuotaServerTests`: Swift Testing suites.
- `DESIGN.md`: design system. Read it before any UI change and update it when you add patterns.

## Commands

- Test: `scripts/test.sh` (adds the Swift Testing macro plugin path required by Command Line Tools). Live tests against the real CLIs and Keychain are skipped unless `QUOTA_LIVE_TESTS=1`.
- Build app bundle: `scripts/build-app.sh`; build and install into `~/Applications`: `scripts/build-app.sh --install`.
- End-to-end check without UI: `~/Applications/Quota.app/Contents/MacOS/Quota --print` (linked accounts, or detected CLI logins when none are linked). `QUOTA_DEBUG=1` logs failed HTTP responses, `QUOTA_DEBUG=verbose` logs every usage response body (never tokens).
- Render UI previews with sample data: `.build/debug/Quota --render-preview <dir>`. AppKit-backed controls (buttons, menus, spinners) render as placeholders there, except in `readme-*.png`, which use the `isStaticPreview` environment flag. Regenerate `docs/screenshots/readme-{light,dark}.png` from it after visible UI changes.
- Check a translation live: `build/Quota.app/Contents/MacOS/Quota --print -AppleLanguages '(it)'`.
- Build `quota-server` (universal, macOS 12.3+): `scripts/build-server.sh` → `build/server/quota-server`.

## Toolchain gotcha

With the macOS 27 SDK, SwiftUI `@State` is a macro whose plugin is missing from Command Line Tools. Keep view state in `ObservableObject`s (see `PopoverRouter`) instead of `@State`.

## Portability

- `QuotaCore` must compile for macOS 12.3 (`quota-server` runs on older always-on Macs): no macOS 13+ APIs such as `URL(filePath:)`, `appending(path:)`, `appending(queryItems:)`, `URL.host()`, `Task.sleep(for:)` or `NSLock.withLock` (use `locked`). `scripts/build-server.sh` is the check.
- `Models.swift`, `Formatting.swift`, `JSON.swift`, `UsagePayload.swift` and `ProviderGlyph.swift` are also compiled into the iOS targets of quota-ios: keep them Foundation/SwiftUI-only (no `Process`, Keychain helpers or AppKit), and keep `ProviderGlyph.swift`'s `import QuotaCore` conditional. `Resources/it.lproj/Localizable.strings` also carries the iOS app's strings. `scripts/make-icon.swift <png> --ios` renders the full-bleed iOS icon.

## iPhone: quota-server and the iOS app

- `quota-server serve` listens on the loopback interface only (port from `--port` or `PORT`, default 4310); a reverse proxy publishes it over HTTPS (for example a `grog serve` site with `run: quota-server serve`, Caddy, or Tailscale Serve). It refreshes every 5 minutes like the app and serves cached data.
- API (version 1, JSON): `GET /health` (no auth), `POST /v1/pair` with `{"code","name"}` → `{"token"}`, `GET /v1/usage` with `Authorization: Bearer <token>` → `UsagePayload` (accounts, windows, issues; never credentials). Unknown window kinds must be skipped by clients.
- `ProviderSnapshot.issue` can accompany partial data. `UsageStore` and `UsageCache` retain earlier windows and their original `fetchedAt` when a recoverable issue arrives without windows. `AccountUsage` propagates that issue; `retryLater` keeps the existing `rateLimited` API kind. Local `tokenUsage` and `resetCredits` stay outside the version 1 payload.
- Pairing: `quota-server pair` prints an 8-digit code, valid 10 minutes, single use, burned after 5 wrong attempts. Tokens and codes are stored only as SHA-256 hashes in `~/Library/Application Support/Quota/Server/devices.json` (mode 600, flock-guarded). `quota-server devices` / `revoke <id>` manage paired devices.
- Accounts are the same `AccountStorage` suite as the app: link them on the server Mac with `quota-server detect`, `link <service>`, `signin ollama`, `unlink <id>`.
- The iOS app (quota-ios) keeps the device token in the Keychain and the last payload in its App Group; the widgets fetch the server themselves every 15 minutes. Keep the API backward compatible: phones may run an older app.

## Accounts

The user decides which accounts are monitored; nothing is linked automatically. Accounts are stored (without secrets) in the `com.turinglabs.quota.shared` defaults suite.

- **Shared login** (`Account.Source.cli`): reuses the CLI's own session (Claude Keychain item `Claude Code-credentials`, falling back to `~/.claude/.credentials.json` when that item has no access token, `~/.codex` via the Codex CLI, `~/.grok/auth.json`, the `~/.ollama/id_ed25519` device key that `ollama signin` linked, Muse Code Keychain item `ai.meta.dev.credentials` account `meta`). Quota does not refresh Codex, Grok, Ollama or Muse tokens itself. A Claude Keychain item with no access token is not a logout: Quota copies the credentials file back over it, because Claude Code treats any Keychain hit as the login and would otherwise ignore the file. When the shared Claude access token is expiring or rejected, Quota renews it at `https://platform.claude.com/v1/oauth/token` with the same JSON body as Claude Code and immediately writes the rotated refresh token to `~/.claude/.credentials.json` and to every Keychain item that held the old refresh token (one attempt at a time, 10-minute cooldown after a failure that is not a rate limit; a 429 waits 30 minutes and then doubles up to 12 hours, remembered in `~/Library/Application Support/Quota/claude-token-backoff.json`, because retrying every few minutes keeps the token endpoint limited; see `SharedClaudeLogin`). It does not launch `claude` to renew: on `invalid_grant` the CLI clears that Keychain item.
- **Linked by Quota** (`.managed`): isolated home at `~/Library/Application Support/Quota/Accounts/<provider>/<uuid>`, signed in through the official CLI in the browser:
  - Codex: `CODEX_HOME=<home> codex login`; usage via `codex app-server` with the same `CODEX_HOME`, so Codex refreshes its own token.
  - Grok: `GROK_HOME=<home> grok login --oauth` inside `script` (Grok expects a TTY); expired tokens are refreshed by running `grok models` with the same home.
  - Claude: `CLAUDE_CONFIG_DIR=<home> claude auth login --claudeai`; credentials live in the scoped Keychain item `Claude Code-credentials-<sha256(NFC(home))[:8]>`. The shared `Claude Code-credentials` item is snapshotted before login and restored afterwards so Claude Code keeps its account. Quota refreshes managed Claude tokens via `https://platform.claude.com/v1/oauth/token`.
  - Ollama Cloud (no CLI): Quota creates an Ed25519 key in `<home>/.ollama/id_ed25519` (OpenSSH format, mode 600), opens `https://ollama.com/connect?name=<hostname>&key=<base64url(authorized key)>` like `ollama signin` does, and polls `POST /api/me` until ollama.com reports the linked user (an unlinked key gets an empty user, not a 401).
- Unlinking a managed account runs the CLI logout (or deletes the scoped Keychain item, or calls `DELETE /api/user/keys/<key>` for Ollama Cloud) and removes its home.

## Data sources

Mirrors Orca (github.com/stablyai/orca, `src/main/rate-limits`, `src/main/*-accounts`):

- Claude: `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`.
- Codex: JSON-RPC `account/read` + `account/rateLimits/read` on `codex app-server`; fallback `GET https://chatgpt.com/backend-api/wham/usage` for the shared login when the CLI is missing. `rateLimitResetCredits` (or `rate_limit_reset_credits` on the HTTP payload) is the bank of ChatGPT rate-limit resets: `availableCount` is the total, and each `credits` entry with status `available` and a future `expiresAt` is listed under the windows. The menu bar stays on the percentages. Quota does not redeem a reset.
- Grok: `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with `X-XAI-Token-Auth: xai-grok-cli`, falling back to `/v1/billing` for monthly budgets. The API omits zero-valued fields: a missing `creditUsagePercent` means 0% only when the weekly `currentPeriod` matches `billingPeriodStart/End` and no field shows explicit zeros or spend (same rule as Orca).
- Ollama Cloud: `GET https://ollama.com/api/balance` (documented in ollama/ollama `docs/api/balance.mdx`: `included.balance_usd` left of `included.allowance_usd`, resetting at `included.period.until`; legacy plans return `included.session`/`included.weekly` with `remaining_percent` and `resets_at`; 10 requests/minute per user). `GET /api/usage` is only the spend history, not the limits and `POST https://ollama.com/api/me` for email and plan. Requests are signed as in ollama/ollama `api/client.go`: `Authorization: <base64 public key blob>:<base64 Ed25519 signature of "<METHOD>,<path>?ts=<unix>">` with the same `ts` in the query (CryptoKit `Curve25519.Signing`). ollama.com answers with Go field names (`Email`, `Plan`), so keys are matched case-insensitively.
- Muse Code: `POST https://api.meta.ai/muse-code/key` with the Meta account token, `x-api-version: 1.0.0` and body `{}`. The response's `subs_usage.window` (a 300-minute window → 5-hour session) and `subs_usage.weekly` are the bars on the accounts page (`used_percent`, `resets_at` as unix seconds). `subs_tier_name` is the plan ("Muse Code High Usage" is shown as "High Usage"). The call returns the account's existing API key and does not mint a second one; Quota discards that key and never logs the body. Under those bars, the popover and `quota --print` also show today's tokens and the last 7 days summed from the local session logs (`~/.local/share/muse/sessions/YYYY/MM/DD/<session>/session.jsonl`, including `subagent/*/session.jsonl`), the same totals Quotax shows. Today resets at the next local midnight. The menu bar stays on the subscription percentages. There is no second-account sign-in. `quota-server` omits Muse Code accounts from `GET /v1/usage` until quota-ios can decode the provider: an unknown `provider` value makes an already-installed iOS app reject the whole payload. The token rows are not part of that payload.

## Rules

- Never log, print or persist tokens. Keychain access goes through `/usr/bin/security` only.
- Never type or handle user passwords: sign-in always happens in the browser on the provider's page.
- Poll no more often than every 5 minutes; the usage endpoints rate-limit aggressive clients.
- `ClaudeUsageGate` enforces Claude's polling budget across the app, server and CLI with a file lock and a five-minute usage cache under `~/Library/Application Support/Quota/ClaudeUsage`. A 429 persists a 30-minute wait, doubling up to 12 hours; a longer `Retry-After` is honored. Menu opening, wake, reset timers and relaunches cannot bypass the gate. Only a 429 from the usage request starts that wait: when the shared login's token endpoint is limited (`ClaudeTokenBackoff`), the fetch reports `retryLater` without touching the gate, so the next poll re-reads the Keychain and uses the token as soon as Claude Code renews it. Cache files contain usage only, never credentials. Managed Claude refresh uses the same JSON request as the shared login and propagates 429 without a second refresh attempt.
- When Meta omits Muse's `subs_usage` for an idle subscription, the user has authorized one minimal inference on app/popover open to restore it: `MuseIdleWake` sends `Reply OK.` with a 16-output-token cap, no tools and no stored response, using the key returned by the existing mint. It is never triggered by timed refresh, CLI reports or the server. A persisted file lock/cooldown prevents duplicate requests (five hours after success, 30 minutes after failure). The key stays in memory and is never logged or cached. Successful subscription bars are cached separately from local token totals; partial failures surface an issue and retain the previous bars. Every linked account retains its menu-bar glyph, using an em dash when no quota reading exists.
- Code, comments and docs in English.

## Token activity

- `TokenHistory.swift` reads linked providers' local CLI session logs and indexes file size/mtime plus hashed event IDs and numeric token counters in `~/Library/Application Support/Quota/TokenActivity/index-v2.json` (mode 600). Never persist prompts, transcripts, credentials or raw responses there. Changed files are streamed with `getline`; unchanged files reuse their numeric index. Increment the index version when parser semantics change.
- Claude counts each message ID once (maximum of repeated streaming usage), adding cache reads/writes to input. Codex uses per-response `token_usage_record.usage` keyed by response ID when available; after the first such record in a file, legacy `token_count` records must be ignored because their cumulative baseline can differ. Earlier legacy-only portions use cumulative deltas and per-call usage after resets. Never alternate the modern and legacy cumulative counters. Grok uses completed turns; Muse uses completed model calls. Reasoning is part of output, cache is part of input. Do not add those subsets again.
- `TokenActivityView` shows 12 Monday-first weeks in the current timezone and only local recorded usage, without network calls. Ollama Cloud is explicitly unavailable for token history. `--print-activity` reports totals, `--render-activity <dir>` renders real-data previews, and `--render-preview <dir>` also emits sample activity previews.

## Localization

- English is the development language: user-facing strings are written in English in code (`String(localized:)` for computed strings, string literals in SwiftUI views).
- Every new user-facing string needs a translation in `Resources/it.lproj/Localizable.strings`. Keys use the compiler's format: `%@` for strings, `%lld` for integers.
- Never put a literal `%` inside a localized string; render percentages with `Text(verbatim:)`.
- Ternaries of string literals passed to `Text` are not localized: wrap each branch in `String(localized:)`.
