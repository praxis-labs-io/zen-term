# Settings card — Appearance + Terminal sections + Theme picker (ZEN-75 PR3)

## Context

Third and final slice of the ZEN-75 Settings-card epic. PR1 shipped the card
foundation + **Keybinds** section (#36); PR2 shipped the **General** (Layout &
Motion) section + Keybinds redesign (#37). PR3 rounds out the card:

- Rename **General → Appearance** and add a **theme picker** to it.
- Add a new **Terminal** section, moving **shell** / **shell-args** into it out
  of Appearance.

The theme picker is the first UI that lets a user *choose* their appearance
rather than hand-editing `theme = <name>` in the config file. There is no
bundled theme catalog today — the built-in Rosé Pine Moon lives in code, and a
`theme = <name>` key loads a ghostty-format file the user drops into
`~/.config/zen-term/themes/`. This PR ships a **bundled catalog** so the picker
is useful on a fresh install, merged with any user-dropped theme files.

Refs ZEN-75. New ticket for this slice on the ZenTerm team.

## Goals

1. Appearance section (renamed) with a **Theme** group at the top, above the
   existing Layout and Motion groups.
2. Terminal section owning the full terminal config — **Font** (family, size),
   **Cursor** (style, blink, thickness), **Input** (option-as-alt, scroll
   multiplier), and **Shell** (shell, shell-args, moved out of Appearance).
3. Extract a shared **`SettingsFormSection`** base from PR2's section so
   Appearance and Terminal share one copy of the numeric/segmented/text row
   builders + live-apply debounce + blank-is-default + focus/reset-all
   machinery (the PR2 review flagged this duplication with only two consumers;
   a third makes the extraction clearly correct).
4. A bundled theme catalog (~16 ghostty-format themes) selectable from a new
   **themed dropdown** control, merged with the user's `themes/` directory.
5. Selecting a theme writes `theme = <name>` immediately; because a full live
   re-theme of the running chrome is out of scope (see Part D), the Theme row
   then offers a **"Restart to apply"** button. Hot reload is a tracked
   follow-up.

## Non-goals (explicit)

- **Hot reload** of the running chrome + terminal surfaces on theme change.
  This is the preferred end state but a broad change (chrome colors are baked
  imperatively at view construction across many views, and the terminal seam's
  `applyTheme` is init-only). Deferred to a follow-up ticket, seeded with the
  investigation lead that ghostty and kitty both expose a live config-reload
  command, plus the `TerminalSurface.applyTheme` seam extension and a chrome
  color re-resolve pass.
- Per-theme editing / authoring inside the app. Users still hand-author custom
  ghostty theme files in `themes/`; the picker only selects.
- Font-family *validation* / a font picker panel — the family is a free-text
  field (like shell); an unknown family falls back per the existing font
  resolution. A native font panel is a later nicety.

---

## Part A — Section restructure + shared form base

### Shared `SettingsFormSection`

PR2's `SettingsLayoutSection` carries the reusable form machinery — numeric
(`FieldBox`) rows with per-field range + blank-is-default, segmented (On/Off,
enum) rows, text rows, the live-apply debounce (`scheduleApply`/`flushApply`/
`runPending`), `commitNumeric`/`write`/`writeOrRemove`, `persist` +
`refreshRows`, the ordered focus `stops` + `moveFocus`, `sectionWillHide`, and
the Reset-all + `ResetFlashLabel`. Extract this into a
`Sources/ZenTerm/SettingsFormSection.swift` base class conforming to
`SettingsSection`, exposing protected builders:

- `addNumericRow(key:caption:blurb:range:read:width:)` — CGFloat knob.
- `addSegmentedRow(key:caption:blurb:options:read:token:)` — enum/bool knob
  (returns the chosen index; `token` maps index → config value;
  `notifiesOnReselect: true` where a resolved default must be pinnable, as
  reduce-motion needs).
- `addTextRow(key:caption:blurb:placeholder:read:width:)` — string knob (blank
  removes the key).

Appearance and Terminal subclass it and only declare their groups + rows;
neither re-implements the debounce/persist/focus/reset plumbing. The base owns
`stops`, `controlForKey`, `scalarKeys`, `rows`, and the scroll assembly via
`SettingsDetail.scroll`.

### Appearance

`SettingsLayoutSection` → **`SettingsAppearanceSection`** (type + file),
`navTitle` "General" → **"Appearance"**. Groups, top-down: **Theme** (the new
dropdown row, Part C), then the existing **Layout** (backdrop-alpha,
window-gutter, pane-gap, drawer fractions, resize step, max-drawer) and
**Motion** (reduce-motion) groups. It **loses** the Shell group.

### Terminal

**New `SettingsTerminalSection`** (`navTitle` "Terminal"), groups top-down. All
rows apply to **new tabs** (labeled), matching how shell already behaves —
these are per-surface config read at surface construction, so no restart is
needed, only a new tab.

| Group  | Row            | Key                   | Control  | Notes |
|--------|----------------|-----------------------|----------|-------|
| Font   | Font family    | `font-family`         | text     | free-text, blank = default |
| Font   | Font size      | `font-size`           | numeric  | range 6–72 |
| Cursor | Style          | `cursor-style`        | segmented| Block / Bar / Underline |
| Cursor | Blink          | `cursor-style-blink`  | segmented| On / Off |
| Cursor | Thickness      | `cursor-thickness`    | numeric  | px, range 1–8 |
| Input  | Option as Alt  | `macos-option-as-alt` | segmented| On / Off |
| Input  | Scroll speed   | `scroll-multiplier`   | numeric  | range 0.1–10 |
| Shell  | Shell          | `shell`               | text     | moved from Appearance |
| Shell  | Shell args     | `shell-args`          | text     | moved from Appearance |

`LayoutFormat` gains small token helpers mirroring `reduceMotionToken`:
`cursorStyleToken`/`parseCursorStyle` (`block`/`bar`/`underline`) and a
bool token pair (`true`/`false`) for the On/Off segments. `read` closures pull
from `GeneralConfig` (`cursorStyle`, `cursorBlink`, `cursorThickness`,
`optionAsAlt`, `scrollMultiplier`, `fontName`, `fontSize`, `shell`, `shellArgs`).

### Wiring

- **Nav order** in `WindowController` (`SettingsOverlay` sections array):
  **Appearance, Terminal, Keybinds**.
- The shell rows' keys (`shell`, `shell-args`) move to Terminal's `scalarKeys`
  so Terminal's Reset-all owns them; Appearance's Reset-all no longer touches
  them. Each section's Reset-all clears only its own keys.
- Both sections keep the shared 2D keyboard model (focus stops,
  `sectionWillHide`, arrows/Tab) via the base, unchanged in feel from PR2.

---

## Part B — Theme catalog

### Bundled resources

Ship ghostty-format theme files as SwiftPM resources under
`Sources/ZenTerm/Themes/` (`.copy` in `Package.swift`, read via `Bundle.module`).
Catalog (~16), display name → file, with light/dark classification:

- **Rosé Pine**: Main (dark), Dawn (light). *(Moon is the built-in default —
  see below — so it isn't a separate bundled file.)*
- **Catppuccin**: Latte (light), Frappé (dark), Macchiato (dark), Mocha (dark)
- **Tokyo Night**: Night (dark), Storm (dark), Day (light)
- **Nord** (dark), **Gruvbox Dark** (dark), **Dracula** (dark),
  **Solarized Dark** (dark), **Everforest** (dark), **Kanagawa** (dark)

Each file is a standard ghostty theme (`background`, `foreground`, `cursor-color`,
`selection-background`, `palette = N=#hex`), parseable by the existing
`GhosttyThemeParser`. Light themes double as light-chrome coverage
(`ChromeThemeDeriver` already derives readable chrome from any terminal palette).

### `ThemeCatalog`

New `Sources/ZenTerm/ThemeCatalog.swift`:

```swift
struct ThemeEntry {
    let name: String          // config token, e.g. "catppuccin-mocha"; nil-name = built-in default
    let displayName: String   // "Catppuccin Mocha"
    let isDark: Bool
    let source: Source        // .builtIn | .bundled | .user
}
```

- `static func entries() -> [ThemeEntry]` returns, in order:
  1. The **built-in** default entry (display "Rosé Pine Moon", the code theme).
  2. **Bundled** entries (the catalog above), sorted by family then variant.
  3. **User** entries — files in `~/.config/zen-term/themes/*` — sorted by name.
- **De-dup / precedence:** a user file whose basename matches a bundled name
  shadows the bundled entry (source `.user`), so a user can override a shipped
  theme. Matching is by config token (basename).
- The **current** selection is resolved from `GeneralConfig.current.themeName`
  (nil ⇒ built-in default entry).

### Resolution (loader change)

`ConfigLoader.resolveThemeURL(configRoot:general:)` gains a bundled lookup so a
`theme = <name>` key resolves against the catalog, not just the user dir:

1. `themeName == nil` → existing legacy `theme` file, else built-in.
2. `themeName` set → **user** `themes/<name>` if present (unchanged), **else**
   the **bundled** resource `Bundle.module/Themes/<name>`, **else** warn +
   built-in (unchanged fallback).

Precedence (user over bundled) matches `ThemeCatalog`'s de-dup. No change to
`GhosttyThemeParser`, `AppTheme`, or `ChromeThemeDeriver`.

### Writing a selection

Selecting an entry writes via the existing `ConfigWriter` scalar path:

- Built-in default entry → **remove** the `theme` key (blank = default, matching
  the Appearance/Terminal blank-is-default convention).
- Any other entry → `ConfigWriter.apply(scalars: ["theme": name])`.

`AppConfig.reload()` runs as usual (re-resolves `Theme.current`, posts
`configDidChange`); the running chrome does not fully re-theme yet (Part D), but
the write is durable so a relaunch adopts it.

---

## Part C — Theme picker (new dropdown primitive)

No dropdown/select primitive exists (only `AppButton`, `FieldBox`, `IconButton`,
`LabeledField`, `SegmentedControl`). Add a keyboard-navigable **`Dropdown`** to
`Sources/ZenTerm/Controls/`:

- A compact menu **button** showing the current entry's display name + a chevron,
  styled from `Theme.current.chrome` roles (rest/hover/focus fills like
  `FieldBox`, accent ring while first responder — reuse the established control
  look). Width sized to the widest entry, capped.
- Activating (Return / Space / click) opens a **lightweight in-card popover
  list** (not `NSMenu` — the card is a fully custom, keyboard-first,
  chrome-themed surface, and a popover list mirrors the palette row styling and
  slots into the card's 2D focus model far more cleanly than a system menu).
  Rows show the entry's display name with an optional faint group header
  (**Bundled** / **Your themes**; the built-in default sits first, ungrouped), a
  trailing Light/Dark hint, and a check on the active entry.
- Keyboard: Up/Down move the highlight, Return selects + closes, Esc closes
  without change. As a card focus stop it bubbles Up/Down at the list
  boundaries to `moveFocus` and Left/Tab per the section's 2D model, exactly
  like `SegmentedControl` does.
- API takes **structured items**, not bare strings, so grouping + hints render:
  `DropdownItem { title: String, group: String?, note: String?, isSelected: Bool }`
  and `Dropdown(items: [DropdownItem], selectedIndex:, onChange: (Int) -> Void)`
  plus the section keyboard hooks (`onArrowUp/onArrowDown/onTab/onBacktab/onEsc`)
  wired in `wireControlKeyboard`. The primitive stays theme-agnostic (no
  `ThemeEntry` coupling); the Appearance section maps catalog entries to
  `DropdownItem`s.

The Theme row in Appearance: caption "Theme", the dropdown as its control, and
(when the selection differs from the running theme) the restart affordance from
Part D as its `controlNote`/adjacent control.

---

## Part D — Apply behavior (restart-to-apply)

A full live re-theme of the running window is out of scope (chrome colors are
baked at construction; see Non-goals). Instead:

- Writing the theme is **immediate** (config updated + `AppConfig.reload()`), so
  any later relaunch or new launch adopts it regardless.
- When the selected theme **differs from the running `Theme.current`**, the
  Theme row reveals a **"Restart to apply"** `AppButton`. It disappears once the
  selection matches the running theme again.
- **`Relauncher`** (`Sources/ZenTerm/Relauncher.swift`): `static func relaunch()`
  spawns a fresh instance, then `NSApp.terminate(nil)`.
  - Packaged `.app` (the `bin/package-app` output, the real distribution):
    relaunch via a detached helper — `/bin/sh -c 'sleep 0.2; open "<bundlePath>"'`
    — so the new instance starts after this one exits.
  - Dev bare executable (`swift run`, no bundle): relaunch
    `Bundle.main.executablePath` directly; if neither is resolvable, no-op with
    a log (the write already persisted, so the user can relaunch by hand).

### Follow-up ticket — hot reload (Drew's preferred end state)

Filed on the ZenTerm team, seeded with:
- **Terminal:** ghostty and kitty both expose a live config-reload command —
  investigate driving that (libghostty path later) and, for the SwiftTerm
  backend now, promote `SwiftTermSurface.applyTheme` to a public
  `TerminalSurface.apply(theme:)` seam method and re-apply to every live surface
  on `configDidChange`.
- **Chrome:** a centralized re-resolve pass so every chrome view re-reads
  `Theme.current.chrome` on `configDidChange` (today only the backdrop
  re-tints), avoiding a half-themed window on light themes.

---

## Files

**New:**
- `Sources/ZenTerm/SettingsFormSection.swift` (shared base extracted from PR2)
- `Sources/ZenTerm/SettingsTerminalSection.swift` (Font/Cursor/Input/Shell)
- `Sources/ZenTerm/ThemeCatalog.swift`
- `Sources/ZenTerm/Controls/Dropdown.swift`
- `Sources/ZenTerm/Relauncher.swift`
- `Sources/ZenTerm/Themes/*.ghostty` (~16 bundled theme files)
- `Tests/ZenTermTests/ThemeCatalogTests.swift`
- `Tests/ZenTermTests/ThemeResolutionTests.swift`
- `Tests/ZenTermTests/TerminalConfigWriteTests.swift` (LayoutFormat tokens +
  write round-trips for the new terminal knobs)

**Modified:**
- `Sources/ZenTerm/SettingsLayoutSection.swift` → renamed
  `SettingsAppearanceSection.swift`, reduced to declaring its groups on the new
  base (nav "Appearance", + Theme group, − Shell group)
- `Sources/ZenTerm/LayoutFormat.swift` (cursor-style + bool token helpers)
- `Sources/ZenTerm/WindowController.swift` (register Terminal section; nav order
  Appearance, Terminal, Keybinds)
- `Sources/ZenTerm/ConfigLoader.swift` (bundled-resource theme resolution)
- `Package.swift` (`.copy("Themes")` resource on the ZenTerm target)
- `docs/config/config` (note the theme catalog + that the picker writes `theme`)

**Unchanged (verified):** `GhosttyThemeParser`, `AppTheme`, `ChromeThemeDeriver`,
`Theme`, `ConfigWriter`, `GeneralConfig`/`GeneralConfigParser` (every terminal
key — `font-family`, `font-size`, `cursor-style`, `cursor-style-blink`,
`cursor-thickness`, `macos-option-as-alt`, `scroll-multiplier`, `shell`,
`shell-args` — and `themeName`/`theme` are already modeled and parsed).

---

## Testing

**Unit:**
- `ThemeCatalogTests`: entries include built-in first, then bundled, then user;
  a user file shadowing a bundled name appears once as `.user`; display names +
  light/dark flags correct for a sample.
- `ThemeResolutionTests` (mirrors the loader's temp-dir pattern): `theme =
  <bundled-name>` with no user file resolves to the bundled resource and parses;
  a user `themes/<name>` file wins over the bundled one; an unknown name warns +
  falls back to built-in; nil name → built-in.
- Theme write round-trip: selecting a non-default entry writes `theme = <name>`
  and reload reflects it; selecting the built-in default removes the key.
- `TerminalConfigWriteTests`: `LayoutFormat` cursor-style + bool token round-trip
  (`cursorStyleToken`/`parseCursorStyle`, on/off); writing each terminal knob
  through `ConfigWriter` then `ConfigLoader.loadGeneralConfig` reflects it, and
  a blank text/number field removes its key (falls back to `builtIn`).

**`bin/check` fully green** (build + `swift test` + `swift format lint --strict`
+ `swiftlint --strict`).

**Manual runbook (`swift run ZenTerm`):**
- Settings nav shows **Appearance, Terminal, Keybinds**. Terminal shows Font /
  Cursor / Input / Shell groups. Editing a knob (e.g. cursor style → Bar, font
  size → 16, shell → a different shell) applies to a **new tab** (open one to
  confirm); Terminal Reset-all clears every Terminal key. Blank a text/number
  field → it reverts to the built-in default (placeholder shown).
- Appearance shows a **Theme** dropdown above Layout. Opening it lists the
  built-in default, the bundled catalog (grouped), and any user `themes/` files,
  with light/dark hints and a check on the active theme. Keyboard: arrows move,
  Return selects, Esc closes; it participates in the card's up/down/Tab focus
  flow.
- Selecting a different theme reveals **"Restart to apply."** Clicking it
  relaunches into the chosen theme (verify against a light theme — e.g.
  Catppuccin Latte — that the whole chrome reads correctly after relaunch).
  Selecting a light and a dark theme both render legibly (no washed-out chrome).
- `cat ~/.config/zen-term/config` shows `theme = <name>`; selecting the built-in
  default removes the line. A hand-dropped `themes/<name>` file appears in the
  picker and, when it shadows a bundled name, wins.

---

## Out of scope (recap)

Hot reload (follow-up ticket), in-app theme authoring, a native font-picker
panel + font-family validation. This PR delivers the section restructure + the
shared form base, the full Terminal config section, the bundled theme catalog +
picker, and restart-to-apply.

## Scope note

With the full Terminal config set + the shared-base extraction added to the
theme catalog/picker/restart work, PR3 is large. It splits cleanly along the
existing seam if preferred: **PR3a** — shared `SettingsFormSection` +
Appearance rename + Terminal section (no theme work); **PR3b** — theme catalog +
`Dropdown` + Theme row + `Relauncher`. Delivered as one PR unless we decide to
split at planning time.
