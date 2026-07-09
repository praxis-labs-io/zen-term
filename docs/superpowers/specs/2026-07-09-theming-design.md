# Theming — bring-your-own ghostty theme (terminal + chrome)

**Ticket:** ZEN-27 · **Date:** 2026-07-09 · **Status:** design approved

## Goal

Make zen-term's appearance config-driven. Point it at a **ghostty-format theme
file** and it colors **both** the terminal and the chrome. With no file present,
the bundled Rosé Pine Moon default renders exactly as today (zero visual change).

## Current state

- `TerminalTheme` (struct, `TerminalKit`) — the seam's terminal appearance
  vocabulary: font + colors. Backend-neutral; `GhosttyConfigWriter` maps it to
  ghostty config, `SwiftTermSurface` maps it to SwiftTerm.
- `Theme.rosePineMoon` (`ZenTerm/Theme.swift`) — the single hardcoded built-in,
  referenced **statically in ~14 sites** across the chrome. Two consumer classes:
  - **Terminal surfaces** — via `TerminalSurfaceConfig(theme:)` (`ShellLaunch`,
    `TabController`).
  - **Chrome UI** — directly: toast colors (`ToastView`, `ToastVariant` uses
    foam/gold/love), window backdrop tint (`WindowController`), tab colors
    (`TabController`), pane background (`PaneCanvasController`).
- No config-file loading and no `UserDefaults` persistence exist yet. Greenfield.

## Scope

**In:**
1. **Single source of truth** — collapse the ~14 `Theme.rosePineMoon` refs to one
   `Theme.current`.
2. **Ghostty-format theme parser** → `TerminalTheme` colors.
3. **Chrome derivation** — chrome color roles derived from the terminal palette.
4. **Minimal `~/.config/zen-term/` loader** — find dir, load one theme file, sane
   defaults, parse error → warn-never-crash. (The substrate ZEN-70/ZEN-71 reuse.)

**Out (explicit):**
- **Font configuration** — ghostty *theme* files carry no font (font is separate
  ghostty config). Font stays the current default (JetBrainsMono Nerd Font Mono,
  14) → configurable later in **ZEN-71 (General config)**.
- **Hot reload** — launch-only for v1. Live re-theming needs
  `ghostty_surface_update_config` per surface + chrome re-tint → follow-up.
- **Per-surface / per-pane theme** — all panes share one theme (no live bug);
  deferred, noted on ZEN-27.
- **Chrome color overrides / own TOML format** — derivation only for v1.

## Architecture

All new types live in `ZenTerm/` (above the seam); `TerminalTheme` stays in
`TerminalKit`.

```
~/.config/zen-term/theme  (ghostty key=value format)
        │
   ConfigLoader ──▶ GhosttyThemeParser ──▶ TerminalTheme (colors; font injected)
        │                                        │
        │                              ChromeThemeDeriver
        │                                        │
        └──────────▶ AppTheme { terminal, chrome } ──▶ Theme.current
                                                          │
   chrome reads Theme.current.chrome  ◀───────────────────┴──────────▶  surfaces get Theme.current.terminal
```

### Components

**`ConfigLoader`** (new, `ZenTerm`)
- *Does:* locates the config dir, reads the theme file if present, assembles the
  `AppTheme`. The one place that touches the filesystem.
- *Interface:* `static func loadAppTheme(configRoot: URL = ConfigLoader.defaultRoot) -> AppTheme`.
  `configRoot` is injectable so tests point at a temp dir.
- *Root:* `$XDG_CONFIG_HOME/zen-term/` if set, else `~/.config/zen-term/` (matches
  ghostty's own resolution).
- *Behavior:* file missing → built-in default `AppTheme`; file present but
  unreadable/unparseable → default + `NSLog` warning. **Never throws to the caller,
  never crashes.** Partial file → per-key fallback (see parser).

**`GhosttyThemeParser`** (new, `ZenTerm`)
- *Does:* parses ghostty theme text (`key = value` lines) into a `TerminalTheme`.
- *Interface:* `static func parse(_ text: String, fontName: String, fontSize: CGFloat, fallback: TerminalTheme) -> TerminalTheme`.
- *Keys consumed:* `background`, `foreground`, `cursor-color`,
  `selection-background`, `palette = N=#rrggbb` (N = 0…15). `#rrggbb` and `#rgb`
  hex forms. Comments (`#`), blank lines, and **unknown keys ignored** — so a full
  ghostty *config* file (with `font-family`, etc.) also parses cleanly; we take
  only the color keys.
- *Font:* injected by the caller (the default), never read from the theme.
- *Robustness:* any missing or malformed color key falls back to the corresponding
  value in `fallback` (the built-in default), so a partial/typo'd theme still
  yields a complete, usable `TerminalTheme`. Symmetric with `GhosttyConfigWriter`,
  which already *writes* this exact format.

**`ChromeThemeDeriver`** (new, `ZenTerm`)
- *Does:* maps a `TerminalTheme` → `ChromeTheme` roles.
- *Interface:* `static func derive(from terminal: TerminalTheme) -> ChromeTheme`.
- *Mapping* (grounded in today's `ToastVariant`: foam/gold/love):

  | Chrome role | ← Terminal source | Rosé Pine value |
  |---|---|---|
  | `background` | `background` | `#191724` |
  | `foreground` | `foreground` | `#e0def4` |
  | `info` / accent | `palette[4]` (foam) | `#9ccfd8` |
  | `warning` | `palette[3]` (gold) | `#f6c177` |
  | `destructive` | `palette[1]` (love) | `#eb6f92` |

**`ChromeTheme`** (new struct, `ZenTerm`)
- The chrome color *roles* the ~14 sites actually use today: `background`,
  `foreground`, `info`, `warning`, `destructive` (each a `TerminalColor`). Sized to
  reality; grows only when a chrome site needs a role it doesn't have.

**`AppTheme`** (new struct, `ZenTerm`)
- `{ terminal: TerminalTheme, chrome: ChromeTheme }`. The unit `Theme.current` holds.

**`Theme`** (existing enum, `ZenTerm`)
- Gains `static let current: AppTheme` (loaded once at launch via `ConfigLoader`).
- Keeps the Rosé Pine Moon values as the built-in **default** `AppTheme` (so no-file
  output is byte-identical to today).
- The ~14 call sites migrate, each classified:
  - a **chrome** use → `Theme.current.chrome.<role>.nsColor`
  - a **terminal-surface** use → `Theme.current.terminal`
  (The implementation plan enumerates all 14 with their classification.)

## Data flow

App launch (before the first window/surface is built):
1. `ConfigLoader.loadAppTheme()` resolves `~/.config/zen-term/theme`.
2. Readable → `GhosttyThemeParser.parse(text, defaultFont, fallback: builtin.terminal)`;
   missing → `builtin.terminal`.
3. `ChromeThemeDeriver.derive(from: terminal)` → `ChromeTheme`.
4. `AppTheme{terminal, chrome}` assigned to `Theme.current`.
5. Chrome reads `Theme.current.chrome.*`; `TerminalSurfaceConfig` is built from
   `Theme.current.terminal`.

Launch-only: `Theme.current` is immutable after load. Changing the theme requires
an app restart in v1.

## Error handling

- Missing dir/file → default, silent (the common first-run case).
- Unreadable/unparseable file → default + one `NSLog` warning naming the path.
- Partial/typo'd file → per-key fallback to the default value; usable theme.
- No path leads to a crash or an empty/black theme.

## Testing

**Unit (`ZenTermTests` — all new types live in the `ZenTerm` target):**
- `GhosttyThemeParser`: a known ghostty theme string → expected colors; a partial
  theme → gaps filled from fallback; malformed color line → that key falls back,
  rest parse; unknown keys (`font-family`, `window-padding`) ignored; a full
  ghostty config file → only colors extracted.
- `ChromeThemeDeriver`: derive from the Rosé Pine terminal theme → `info` == foam,
  `warning` == gold, `destructive` == love, bg/fg pass through.
- `ConfigLoader`: `configRoot` at an empty temp dir → default `AppTheme`; a temp
  dir with a malformed `theme` file → default `AppTheme`, no throw.
- Round-trip (nice-to-have): `GhosttyConfigWriter.configText(default)` →
  `GhosttyThemeParser.parse` → equal terminal colors (format symmetry).

**Manual runbook:**
1. No `~/.config/zen-term/` → launch → identical to today (Rosé Pine Moon), terminal
   + chrome.
2. Drop a *different* ghostty theme (e.g. a light one from ghostty's theme repo) at
   `~/.config/zen-term/theme` → launch → terminal **and** chrome recolor (backdrop
   tint, toast accents, tab colors all follow).
3. Malformed file (garbage line) → launch → no crash, default theme, one log
   warning.

## Decisions (locked)

- **Format:** ghostty-native theme file; chrome colors **derived** from the palette.
- **Font:** colors-only this ticket; font → ZEN-71.
- **Reload:** launch-only for v1; hot-reload is a follow-up.
- **File:** `~/.config/zen-term/theme` (ghostty key=value), `XDG_CONFIG_HOME`
  respected.
