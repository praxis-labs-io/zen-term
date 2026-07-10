# Settings card + Keybinds section — ZEN-75 PR1 (foundation)

## Context

Every app-level config is read once at launch from `~/.config/zen-term/config`
(plus `themes/<name>`) with no way to see or change it short of hand-editing a
dotfile and restarting. ZEN-75 makes config manageable in the UI: a **Settings
card** — a `ModalOverlay` with a left nav of sections and a right detail pane —
opened from ⌘P → "Settings…" and a reserved chord. Each section reads live
values and, on change, **writes back to** `config` (the file stays canonical)
and **applies live to running surfaces — no restart.**

ZEN-75 is epic-sized, so it ships as **three PRs sliced by live-apply
mechanism** (each PR builds exactly one), not by arbitrary size:

- **PR1 — foundation + Keybinds** (this spec). The config writer, the
  save→reload→apply seam, the Settings shell, the shared keyboard-focus engine,
  and the Keybinds section — which applies live through the *already-existing*
  `KeyInterceptor.setKeymap` seam, the lowest-risk apply path.
- **PR2 — Layout & Motion** (later child ticket). Scalar writes + chrome
  constraint re-layout + backdrop-tint update + reduce-motion. Chrome-only
  re-apply, no terminal-surface risk.
- **PR3 — Theme + Terminal** (later child ticket). The net-new terminal-surface
  re-theme/restart seam, built once and used by both sections. Absorbs ZEN-79.

Child tickets for PR2/PR3 are created when picked up (just-in-time, per the
project's Linear rules), not up front.

**Blocked-by note:** ZEN-81 (shared control primitives — `AppButton`,
`SegmentedControl`, `FieldBox`, `LabeledField`) shipped on the ZEN-78 branch;
this PR builds on it.

## Decisions (settled in brainstorming)

- **Scope** = PR1 only (foundation + Keybinds).
- **Save model** = **live apply-as-you-go**. Every committed edit writes the
  file and applies immediately. No dirty state, no Save button, no discard; Esc
  just closes the card. ⌘Return = commit the current field and close.
- **Revert** = every editable row has its own **reset-to-default** (shown only
  when the value differs from the built-in default), plus a section-level
  **Reset all to defaults**.
- **Re-apply seam** = flip `GeneralConfig.current` / `Theme.current` from
  `static let` to `static private(set) var`; a `reload()` re-resolves them from
  disk and posts a change notification; consumers subscribe. PR1 wires one
  consumer (the keymap).
- **Settings nav** = built now as foundation; PR1 registers a single section
  (Keybinds). The nav grows as PR2/PR3 land — no stubbed "coming soon" rows.
- **Keybind conflict** = **block**. Capturing a chord already bound to another
  action is refused inline, naming the current owner; the chord is never
  double-owned. Reset/rebind the owner first to free it.

## Architecture

### A. `ConfigWriter` (new — `Sources/ZenTerm/ConfigWriter.swift`)

The counterpart to `GeneralConfigParser`. Unlike `WorkspacesWriter` (which
appends whole `[Title]` INI sections), `config` is a flat `key = value` file, so
editing means **updating keys in place** while preserving comments, blank lines,
and unknown keys verbatim. The complete writer (both paths) is built here — PR1's
Keybinds exercises only the keybind path, but PR2/PR3 depend on the scalar path,
so it lands fully tested in the foundation PR.

```swift
enum ConfigWriter {
    /// Apply scalar key edits, scalar removals (reset-to-default), and/or a
    /// keymap override set to the `config` file, in place. Round-trip:
    /// GeneralConfigParser.parse(write(edits)) reflects every edit, and untouched
    /// lines (comments / unknown keys / blanks) survive verbatim.
    static func apply(
        scalars:  [String: String] = [:],           // set/replace: ["font-size": "15"]
        removals: Set<String> = [],                  // reset-to-default: delete the active line
        keybinds: [Chord: KeyInterceptor.ReservedChord]? = nil,  // nil = leave keybind lines untouched
        configRoot: URL = ConfigLoader.defaultRoot
    ) throws
}
```

Algorithm:

- Read the whole file (absent → start empty), split into lines.
- **Scalar set** — an active (uncommented) `key = …` line exists → replace the
  value in place, keep any trailing `# comment`. Only a commented default
  (`# key = …`) exists → insert an active `key = value` line right after it.
  Fully absent → append at end.
- **Scalar removal** (reset-to-default) — delete the active `key = …` line. The
  commented default / absence returns and the loader falls back to `builtIn`.
  This is how per-row reset works for the scalar sections (PR2/PR3).
- **Keybind block** — the caller hands the full intended reserved-action map;
  the writer **diffs it against `KeymapDefaults.map`** and emits
  `keybind = <action>=<chord>` lines (via `ReservedChord.actionToken` +
  `Chord.configToken`) only for bindings that differ from a default. The block
  replaces the existing `keybind =` lines at their anchor (the first keybind
  line's position; else immediately after the `# ─ Keybinds ─` header comment;
  else appended at end). Reverting a binding to its default drops its line.
- **Floats are never touched** — `float =` lines and float `key:` chords stay
  verbatim. The Keybinds editor excludes `toggleToolFloat` from its model, and
  the diff excludes float chords, so editing keybinds can never clobber a float.
- Same safety guards as `WorkspacesWriter`: an unreadable existing file
  **throws without clobbering** (never treated as empty); atomic write through
  `url.resolvingSymlinksInPath()` (a dotfiles-symlinked config keeps pointing at
  its target); `createDirectory(withIntermediateDirectories:)` on first write.

Supporting addition — **`Chord.configToken: String`** (`Sources/ZenTerm/Chord.swift`):
the word form `cmd+shift+g` (mirrors the existing `displayGlyph`'s glyph form
`⌘⇧G`), the inverse of `Chord.parse`. Modifiers in the repo's order
(cmd, shift, opt, ctrl) then the key. Unit-tested to round-trip with `parse`.

### B. `AppConfig` re-apply seam (new — `Sources/ZenTerm/AppConfig.swift`)

The save→reload→apply loop. Today `GeneralConfig.current` and `Theme.current`
are immutable launch-only `static let`s read at construction by ~40 sites.

- Each flips to `static private(set) var` (lazy initialization unchanged; every
  existing read site keeps working — it just reads a `var` now).
- Each type gains a `static func reloadCurrent()` that reassigns its own
  `current` from `ConfigLoader` (the `private(set)` setter is file-local, so the
  reload lives on the type). `Theme.reloadCurrent()` runs **after**
  `GeneralConfig.reloadCurrent()`, because the theme loader reads the general
  config for the font.
- **`AppConfig.reload()`** calls both, then posts
  `Notification.Name.configDidChange`.
- **Invariant from PR1 on:** after any `ConfigWriter.apply(…)`, call
  `AppConfig.reload()`; `current` then always mirrors the file.

Consumers subscribe to `configDidChange`. **PR1 wires exactly one:**
`AppDelegate` (which owns the single `KeyInterceptor`, `keys`) subscribes and
runs `keys.setKeymap(GeneralConfig.current.keymap)`. `reload()` is the shared
post-point PR2 (chrome relayout + `MotionConfig.apply`) and PR3 (surface
re-theme) hang their consumers off later.

### C. Shared 2D keyboard-focus engine (new — `Sources/ZenTerm/KeyboardFocus.swift`)

`AddWorkspaceOverlay` owns a 2D focus model (↑/↓ between rows, ←/→ within a row,
field-editor-aware first-responder detection). The Settings card must feel like
the same system, so the **traversal engine** extracts and both cards run it.
`verticalStops()` is inherently per-overlay (each card has different rows), so it
*stays* in each overlay; what lifts out is the mechanism:

```swift
enum KeyboardFocus {
    /// True if `view` holds first responder, resolving a text field's field
    /// editor (the actual responder while editing) back to the field itself.
    static func isFocused(_ view: NSView, in window: NSWindow?) -> Bool

    /// The next index when stepping `delta` from `from` within `count` stops,
    /// clamped at the ends (nil = no move). Pure; unit-tested.
    static func step(from: Int?, delta: Int, count: Int) -> Int?
}
```

- `isFocused` moves verbatim out of `AddWorkspaceOverlay`; `step` is the pure
  clamp/step logic factored out of its `moveVertical`. `AddWorkspaceOverlay`
  refactors to call both — behavior-preserving (its runbook still passes).
- `SettingsOverlay` composes them for **two** stop-groups: ↑/↓ within the nav
  list; →/Tab enters the detail pane (focus its first stop); ←/Shift-Tab off the
  detail's first stop returns to the nav. Fully operable without the mouse.

### D. `SettingsOverlay` shell (new — `Sources/ZenTerm/SettingsOverlay.swift`)

A `ModalOverlay` like the palettes — shared `BackdropView` / `CardView`,
`FloatShadow`, `Motion.springScaleFade`, `Theme.current.chrome` roles — but a
**left nav ↔ right detail** split. Section-agnostic so it grows across PRs:

```swift
protocol SettingsSection: AnyObject {
    var navTitle: String { get }
    func makeDetailView() -> NSView
    func detailStops() -> [NSView]   // participates in the shared focus ring
}
```

- The shell owns nav selection and focus routing (via `KeyboardFocus`). Esc
  closes; backdrop click closes; the card is sized larger than the palettes
  (nav + detail), capped at 0.92 of the window like `AddWorkspaceOverlay`.
- **PR1 registers exactly one section** (Keybinds). The nav is a real,
  keyboard-navigable list that gains entries in PR2/PR3 — no stubbed rows.

Entry points (all following the existing single-slot modal machinery in
`WindowController`):

- New `KeyInterceptor.ReservedChord.openSettings` case, with its
  `actionToken` = `open_settings` and `init?(token:)` inverse
  (`Sources/ZenTerm/Keybinds.swift`).
- `CommandCatalog` "Settings…" entry (Tools category), included in
  `commands(tabCount:)`.
- `ModalKind.settings` + its `selfToggle` mapping in `WindowController`;
  `WindowController.openSettings()` builds and presents the overlay via
  `presentModal(_, kind: .settings)`. The lazygit / tool-float / palette
  live-switch gates gain `.settings` alongside the existing cases.
- **Default binding `open_settings = cmd+,`** — the macOS-standard Preferences
  chord, currently unbound. Added to `KeymapDefaults.map`. It is itself
  rebindable from within the Keybinds section (dogfood).
- The dock lights nothing for Settings (`renderDock` still keys
  `paletteOpen` on `.commandPalette` only — unchanged).
- `AppDelegate`'s `isModalOverlayOpen` already covers any modal, so ⌘N /
  copy-paste gate correctly while Settings is open — no change needed.

### E. Keybinds section (new — `Sources/ZenTerm/SettingsKeybindsSection.swift`)

- **Editable actions** = every fixed `ReservedChord` **except
  `toggleToolFloat`** (float-owned, file-only), *including* currently-unbound
  actions (`addWorkspace`, `openSettings`) so they can be bound. Grouped by
  category for scanability (Splits · Navigation · Resize · Tabs · Drawers ·
  Surfaces & Tools); `selectTab(1…9)` shown as its nine rows.
- **Each row** — action label · current chord rendered with the existing
  `KeycapView` · a record affordance · a reset-to-default control (visible only
  when the binding differs from its default).
- **Capture** — focus a row's recorder, press a chord → `Chord(event:)`. Esc
  cancels the capture. Inline validation:
  - **≥1 modifier required** ("Needs at least one modifier") — matches the
    reserved-chord rule in `Chord.parse`.
  - **Conflict = block** — if the chord is already bound to another editable
    action, the capture is refused with a naming message ("⌘P is already bound
    to Command Palette"). The chord is never double-owned; free it by
    resetting/rebinding its current owner.
- **On commit** (rebind / clear / reset) — recompute the intended
  reserved-action map, `ConfigWriter.apply(keybinds:)`, `AppConfig.reload()`,
  keymap consumer applies live. The row's keycap re-reads
  `GeneralConfig.current.keymap`. No restart.
- **Reset** — per-row (drop that override → its `keybind =` line is removed →
  the default chord returns) and section-level **Reset all to defaults** (clears
  every override → no `keybind =` lines remain).

## Files

**New:** `ConfigWriter.swift`, `AppConfig.swift`, `KeyboardFocus.swift`,
`SettingsOverlay.swift`, `SettingsKeybindsSection.swift`,
`Tests/ZenTermTests/ConfigWriterTests.swift`.

**Modified:** `Chord.swift` (+`configToken`), `GeneralConfig.swift` /
`Theme.swift` (`static let` → `static private(set) var` + `reloadCurrent()`),
`Keybinds.swift` (+`open_settings` token + `openSettings` default binding),
`KeyInterceptor.swift` (+`openSettings` case), `CommandCatalog.swift`
(+"Settings…"), `WindowController.swift` (`ModalKind.settings` + `openSettings()`
+ live-switch gates), `AppDelegate.swift` (`configDidChange` subscription →
`setKeymap`), `AddWorkspaceOverlay.swift` (refactor to `KeyboardFocus`),
`ChordTests.swift` / `CommandCatalogTests.swift` (new expectations),
`docs/config/config` (document `open_settings` + live-apply note).

## Testing

**Unit — `ConfigWriterTests`** (mirrors `WorkspacesWriterTests` idioms:
`makeTempDir()`, injected `configRoot`, teardown cleanup):

- Scalar set replaces an active line's value, preserving a trailing `# comment`.
- Scalar set inserts an active line right after a commented default.
- Scalar set appends when the key is entirely absent.
- Scalar removal deletes the active line (default returns).
- Keybind-block regen: only non-default bindings emitted, at the anchor;
  `ReservedChord.actionToken` + `Chord.configToken` forms verified.
- Keybind reset removes the corresponding line.
- Comments, unknown keys, and blank lines survive verbatim
  (`GeneralConfigParser.parse(ConfigWriter → text)` reflects the edits; untouched
  lines byte-identical).
- Unreadable existing file (`Data([0xFF,0xFE,0xFF])`) throws without clobbering.
- Writes through a symlink (link type preserved, content lands in the target).
- **Editing keybinds leaves `float =` lines untouched.**

**Unit — other:**

- `ChordTests`: `configToken` round-trips with `Chord.parse`.
- `KeyboardFocus.step`: pure clamp/step logic across boundaries.
- `CommandCatalogTests`: "Settings…" present; unbound-shortcut handling extended
  to `openSettings` (the `addWorkspace` precedent).
- `ReferenceConfigTests` stays green after the doc edit.

**GUI runbook** (`swift run ZenTerm`):

- ⌘, and ⌘P → "Settings…" both open the card.
- Drive nav → detail → row entirely by keyboard (no mouse): ↑/↓ in nav, →/Tab
  into detail, ←/Shift-Tab back, Esc closes.
- Rebind an action (focus row, press chord); confirm it works **immediately, no
  restart**, and `cat ~/.config/zen-term/config` shows the `keybind =` line with
  the surrounding comments intact.
- Capture a chord already in use → inline block naming the owner.
- Capture a modifier-less key → inline "needs a modifier".
- Per-row reset restores the default and removes the line; Reset-all clears all
  overrides.
- **ZEN-43 regression:** ⌘P / ⌘⇧P / Add-Workspace / Settings all live-switch to
  each other; a tab-bar click while Settings is open dismisses it; the dock
  button lights only for the command palette.
- `bin/check` fully green (build + `swift test` + `swift format lint --strict` +
  `swiftlint --strict`).

## Out of scope (PR1)

- The Terminal, Theme, and Layout & Motion sections (PR2/PR3).
- The terminal-surface re-theme/restart seam (PR3).
- Watching external file edits for live reload — manual reload is ZEN-80.
- Tool-float (`float =`) editing — stays file-only.

## Future PRs (child tickets, created when picked up)

- **PR2 — Layout & Motion:** backdrop alpha, window gutter, pane gap, drawer
  fractions, resize step, max-drawer fraction, reduce-motion, shell/args.
  Scalar writes via `ConfigWriter`; live re-apply via chrome constraint
  re-layout + backdrop-tint update + `MotionConfig.apply`, all off the
  `configDidChange` seam. No terminal-surface changes.
- **PR3 — Theme + Terminal:** theme picker (from `themes/`) + font/cursor/
  scroll/option-as-alt. The net-new part is a terminal-surface re-theme/restart
  seam (no live re-theme exists today); built once and consumed by both
  sections. Absorbs ZEN-79.
