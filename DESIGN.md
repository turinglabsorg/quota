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

## Components

- **Status label** (`StatusLabelView`, `ProviderSnapshot.menuBarWindows`): glyph + percentage per linked account, or glyph + two stacked percentages (session, weekly) each colored by its own level, with the glyph taking the tighter one's color; falls back to the `gauge.with.dots.needle.33percent` symbol when nothing is available.
- **Account card** (`AccountCard`): header (glyph, provider name, account email in 11 pt secondary, plan badge, `ellipsis` menu with source and "Unlink account"), one `WindowRow` per window, optional `IssueLine`.
- **Empty state**: card with title, one-line explanation and a small `borderedProminent` "Add account" button.
- **Add account panel** (`AddAccountPanel`): back chevron + title header; one `ProviderLinkCard` per provider with the detected CLI login ("Link" small bordered button, or "Linked" with checkmark) and a sign-in row ("Sign in to another account…" → spinner + "Finish signing in in your browser…" + "Cancel", or `IssueLine` + "Try again"); footnote explaining that sign-in happens in the browser.
- **Window row**: label, value + suffix (`left`/`used`), usage bar, reset countdown (absolute date on hover).
- **Issue line**: SF Symbol + secondary text; supports inline code via Markdown backticks.

## Copy

UI copy is English with an Italian localization (`Resources/it.lproj`). Sentence case, short, no exclamation marks. Countdown format: `2h 10m`, `3d 4h` (`3g 4h` in Italian), `12m`. Relative time: `now`, `3 min ago`, `2 h ago`.
