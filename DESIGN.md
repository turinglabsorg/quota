# Quota design system

Quota is a native macOS menu bar utility. It should feel like part of the system: quiet in the menu bar, dense and legible in the popover, never decorative for its own sake.

## Principles

- **The user chooses.** Nothing is monitored until the user links an account.
- **Glanceable first.** The menu bar shows one number per linked account: the tightest account-wide window. When an account reports both a 5-hour session and a weekly (or monthly) window, it shows both, stacked: session above, weekly below. Model-scoped limits (e.g. weekly Fable) appear only in the popover because they do not block the whole account.
- **Color means state.** Neutral when healthy, orange when running low, red when nearly exhausted. Brand color is limited to the Claude glyph in the popover.
- **Native materials.** Popover uses the system `NSPopover` material, SF Pro, and system semantic colors so light/dark and accessibility settings work for free.

## Color

| Token | Value | Use |
| --- | --- | --- |
| `level.normal` | `Color.primary` (menu bar), `Color.green` (bars) | More than 20% remaining |
| `level.warning` | `Color.orange` | 6–20% remaining (≥ 80% used, same threshold as Orca) |
| `level.critical` | `Color.red` | 5% or less remaining |
| `accent.claude` | `#D97757` | Claude glyph in the popover |
| `accent.codex`, `accent.grok`, `accent.ollama` | `Color.primary` | Monochrome brands |
| `surface.card` | `Color.primary` at 5% opacity | Provider cards |
| `surface.track` | `Color.primary` at 9% opacity | Empty part of usage bars |
| `surface.badge` | `Color.primary` at 7% opacity | Plan badge |

Stale data (last refresh failed but previous data is shown) renders at 55% opacity in the menu bar.
Every linked account keeps its glyph visible, including during loading and provider failures. A glyph with no quota reading shows an em dash; previously fetched quota percentages remain visible and dimmed through transient failures.

## Typography

System font (SF Pro) only. Digits always use `monospacedDigit()` so values do not jitter.

| Role | Size | Weight |
| --- | --- | --- |
| Menu bar value | 12 | medium |
| Menu bar stacked values | 8.5 | semibold |
| Popover title, provider name | 13 | semibold |
| Window label | 12 | regular |
| Window value | 12 | semibold |
| Secondary text (subtitle, reset, issues, suffix) | 11 | regular, `.secondary` |
| Plan badge | 10 | medium, `.secondary` |

## Spacing and shape

- Popover width 320 pt; header padding 16 horizontal, 14 top, 12 bottom; card list padding 10.
- Cards: 12 pt padding, 10 pt continuous corner radius, 8 pt gap between cards, 12 pt gap between rows.
- Usage bar: 5 pt tall capsule; non-zero values render at least 5 pt wide.
- Menu bar: 7 pt horizontal padding, 9 pt between providers, 3 pt between glyph and value, glyph 11 pt. Stacked values sit at -2.5 pt spacing, closer than their line boxes, to leave room above and below.

## Glyphs

Custom stroked shapes, line width 15% of the glyph size, round caps and joins, drawn in `ProviderGlyph.swift`:

- **Claude**: ten-ray burst with alternating ray length.
- **Codex**: terminal prompt `>_`.
- **Grok**: open ring with a diagonal slash.
- **Ollama Cloud**: llama head, two ears leaning outwards over a rounded head with two eye dots.
- **Muse Code**: four-point spark, stroked closed. No separate sign-in row: only the local `muse` login can be linked.

## Components

- **Status label** (`StatusLabelView`, `ProviderSnapshot.menuBarWindows`): glyph + percentage per linked account, or glyph + two stacked percentages (session, weekly) each colored by its own level, with the glyph taking the tighter one's color; falls back to the `gauge.with.dots.needle.33percent` symbol when nothing is available.
- **Account card** (`AccountCard`): header (glyph, provider name, account email in 11 pt secondary, plan badge, `ellipsis` menu with source and "Unlink account"), one `WindowRow` per window, optional token rows, optional reset credits, optional `IssueLine`.
- **Empty state**: card with title, one-line explanation and a small `borderedProminent` "Add account" button.
- **Add account panel** (`AddAccountPanel`): back chevron + title header; one `ProviderLinkCard` per provider with the detected CLI login ("Link" small bordered button, or "Linked" with checkmark) and a sign-in row ("Sign in to another account…" → spinner + "Finish signing in in your browser…" + "Cancel", or `IssueLine` + "Try again"); footnote explaining that sign-in happens in the browser.
- **Window row**: label, value + suffix (`left`/`used`), usage bar, reset countdown (absolute date on hover).
- **Token row** (Muse Code, under the windows): period label (`Today`, `Last 7 days`), compact total (`45.2k`, `1.25M`) + `tokens`, one secondary line for input, output, cache, reasoning, sessions and steps, and the reset countdown when the period has one (today resets at the next local midnight).
- **Reset credits** (Codex / ChatGPT, under the windows): label `Resets`, count `3 available`, then one secondary line per unused credit (`Full reset`, `expires in 3d 4h`, absolute date on hover). A count with no detail rows shows the count only. Used or expired credits are omitted.
- **Quota server panel** (`ServerPanel`, settings menu → "Quota server…"): back chevron + title header; one card with either the pairing form (one-line instruction, server address and 8-digit code fields, small `borderedProminent` "Pair" + spinner, `IssueLine` on failure) or "Connected to" + host + small destructive "Disconnect"; footnote on what connecting changes. While connected, the usage panel's "Add account" link becomes `server.rack` + "Linked on <host>" (opens the panel), the card menu shows only that line, and the empty state says no accounts are linked on the server.
- **Issue line**: SF Symbol + secondary text; supports inline code via Markdown backticks.
- **Token activity**: the header's 3×3 grid opens a 320 pt panel with a 12-week Monday-first heatmap. Cells are 17 pt squares with 3 pt radii and 4 pt vertical gaps; five intensities encode daily processed tokens by the selected provider's active-day quartiles (neutral at 6% opacity for zero, green at 25/45/70/100%; Claude uses orange). Future days are disabled and faded. Clicking a cell selects its date, draws a primary outline, and shows provider totals plus input/output/cache below. The provider menu filters both the grid and details; All providers is the default. The caption explains local-only coverage and cache accounting. History loads off the main thread on demand. Counts use k/M/B suffixes.
- Claude rate-limit issues include the countdown to the next permitted attempt. Opening the popover uses the same five-minute freshness window as automatic polling.
- If Meta omits Muse subscription windows while idle, opening Quota may send one minimal request to restore the five-hour and weekly bars. This is triggered by opening the app or popover, never by the automatic refresh timer. Cached bars remain visible with an issue when fresh subscription data is unavailable.

## Copy

UI copy is English with an Italian localization (`Resources/it.lproj`). Sentence case, short, no exclamation marks. Countdown format: `2h 10m`, `3d 4h` (`3g 4h` in Italian), `12m`. Relative time: `now`, `3 min ago`, `2 h ago`, `3d 4h ago`.
