# Settings card — Layout & Motion section (ZEN-75 PR2 / ZEN-86)

**Status:** approved
**Ticket:** ZEN-86 (slice 2 of the ZEN-75 Settings-card epic; PR1 = foundation + Keybinds, merged in #36)

## Goal

Add a **Layout & Motion** section to the existing Settings card (`SettingsOverlay`): a
scalar-config editor for the chrome layout knobs, motion preference, and shell launch fields.
Edits write back to `~/.config/zen-term/config` via the PR1 `ConfigWriter` and apply **live** to
running windows wherever the value isn't owned by runtime state — no restart.

## Context (what PR1 already gives us)

- `SettingsOverlay` — a `ModalOverlay` with a left nav + right detail pane, keyboard-first 2D
  focus, Esc/backdrop dismiss. Registered sections are supplied by `WindowController.openSettings`
  (today just `[SettingsKeybindsSection]`).
- `SettingsSection` protocol — `navTitle`, `onExitToNav`, `onClose`, `makeDetailView()`,
  `detailStops()`.
- `ConfigWriter.apply(scalars:removals:keybinds:configRoot:)` — in-place flat-file editing that
  preserves comments/unknown keys; scalar set (`scalars`), reset-to-default (`removals`), atomic
  write through symlinks. **Already built and tested in PR1.** This section is its first scalar
  consumer.
- `AppConfig.reload()` — re-resolves `GeneralConfig.current` / `Theme.current`, then posts
  `.configDidChange`. PR1 wired one observer (`AppDelegate` → keymap).
- Shared control primitives (ZEN-81): `AppButton`, `SegmentedControl`, `FieldBox`, `LabeledField`.
  **No slider/stepper exists yet.**
- The Keybinds list pattern: flipped-document + `SlimScroller` scroll view, grouped rows with
  uppercase captions, per-row reset icon shown only when overridden, section-level "Reset all",
  inline validation message per row.

## The knobs

All live on `GeneralConfig` (`GeneralConfig.builtIn` holds the defaults). Config keys are the
kebab-case names `GeneralConfigParser` already reads.

| Config key | Field | Control | Range · step · default | Live re-apply |
|---|---|---|---|---|
| `backdrop-alpha` | `backdropAlpha: CGFloat` | Slider | 0–1 · 0.02 · 0.82 | **live** — re-tint |
| `window-gutter` | `windowGutter: CGFloat` | Numeric field (px) | 0–64 · 1 · 8 | **live** — relayout |
| `pane-gap` | `panelGap: CGFloat` | Numeric field (px) | 0–64 · 1 · 8 | **live** — relayout |
| `bottom-drawer-fraction` | `bottomDrawerFraction: CGFloat` | Slider | 0.1–0.9 · 0.01 · 0.28 | new tabs |
| `right-drawer-fraction` | `rightDrawerFraction: CGFloat` | Slider | 0.1–0.9 · 0.01 · 0.30 | new tabs |
| `drawer-resize-step` | `drawerResizeStep: CGFloat` | Numeric field (px) | 10–200 · 1 · 40 | **live** (already) |
| `max-drawer-fraction` | `maxDrawerFraction: CGFloat` | Slider | 0.3–0.95 · 0.01 · 0.70 | **live** (already) |
| `reduce-motion` | `reduceMotion: ReduceMotion` | Segmented | System · On · Off | **live** |
| `shell` | `shell: String?` | Text field | optional · nil | new tabs |
| `shell-args` | `shellArgs: [String]` | Text field | optional · [] | new tabs |

**Groups in the section** (uppercase captions, mirroring Keybinds):
1. **Layout** — backdrop-alpha, window-gutter, pane-gap, bottom-drawer-fraction,
   right-drawer-fraction, drawer-resize-step, max-drawer-fraction.
2. **Motion** — reduce-motion.
3. **Shell** (caption notes "new tabs") — shell, shell-args.

Then the section-level **Reset all to defaults** as the final focus stop.

### Live-apply reality (from the seam map)

- **Already live** (read fresh at use, no hook): `drawer-resize-step`, `max-drawer-fraction`
  (resize clamp), `reduce-motion` (animations read the `Motion` closure live).
- **Contained hook needed** (read once at window build today): `backdrop-alpha`, `window-gutter`,
  `pane-gap`.
- **Runtime-owned / new-tab-only** (deliberately NOT forced live): `bottom-drawer-fraction`,
  `right-drawer-fraction` (seeded once into a per-tab ratio that ⌥-resize then owns — a
  hand-resized drawer must keep its size), and `shell`/`shell-args` (consumed only at PTY spawn;
  running shells can't retro-apply, new tabs do).

Rows in the runtime-owned group carry an honest "applies to new tabs" caption so the behavior
reads as intentional, not broken.

## New shared primitive — `Controls/Slider.swift`

A theme-driven, keyboard-focusable horizontal slider for a bounded scalar. Mirrors
`SegmentedControl`'s keyboard contract so it drops into the 2D focus model:

- `init(value:range:step:onChange:)`; `value` clamped to `range`, quantized to `step`.
- Draws a track + filled portion + a thumb, all from `Theme.current.chrome` roles
  (`ink(alpha:)` track, `accent` fill/thumb). A trailing value label shows the current number.
- `acceptsFirstResponder`; accent focus-ring while first responder (own `drawFocusRingMask` no-op,
  same as `SegmentedControl`).
- Keyboard: `←`/`→` nudge by `step` (clamped) and fire `onChange`; `↑`/`↓` bubble via
  `onArrowUp`/`onArrowDown` to move between rows; mouse drag/click sets the value.
- No hardcoded colors (chrome rule); no force-unwrap.

It joins the ZEN-81 shared set; PR3 (Terminal) reuses it for `cursor-thickness` / `scroll-multiplier`.

## The section editor — `SettingsLayoutSection.swift`

A `SettingsSection` mirroring `SettingsKeybindsSection`'s scaffold (flipped doc + `SlimScroller`,
grouped rows with 18pt group gaps, no redundant in-pane title, `detailStops()` = each row's
control + Reset-all).

**Row view — `LayoutRow.swift`** (a scalar-editing row):
- Caption label + control (Slider / numeric `FieldBox` / `SegmentedControl` / text `FieldBox`) +
  a per-row reset icon (`AppButton(variant:.muted, symbol:"arrow.uturn.backward")`, shown only
  when overridden) + an inline validation message (`LabeledField`-style).
- `render(isOverridden:)` toggles the reset icon; `showMessage(_:)` for validation.
- Boundary-aware: numeric/text `FieldBox` rows keep normal cursor editing; the row exposes
  `onExitToNav` (Left at cursor-start), value-change, and reset callbacks to the section.

**Edit flow** (per row, on change): validate → on valid, `ConfigWriter.apply(scalars: [key: rendered])`
→ `AppConfig.reload()` → re-read `GeneralConfig.current`, refresh every row. On a write failure,
report on the edited row and roll the in-memory model back to disk state (same guard pattern PR1
added to Keybinds).

**Reset** (per row): `ConfigWriter.apply(removals: [key])` → reload → refresh. Removing the key
reverts the value to `builtIn`. **Reset all**: `removals` = every key this section owns.

**`isOverridden(key)`**: parsed current value ≠ the `builtIn` value for that field.

**Value ↔ config-string:**
- Floats render with the minimal decimals needed (no `0.8200000001`); parse tolerantly.
- `reduce-motion` ↔ `system` / `on` / `off`.
- `shell-args` ↔ a single whitespace-joined string (v1; advanced quoting stays a file edit).
- Empty `shell` / `shell-args` = reset (removal), not an empty-string write.

### Keyboard model (approved)

- `↑`/`↓` — move between rows (and to Reset-all).
- `←`/`→` — operate the focused control (slider nudge · segment pick · text cursor). A numeric/text
  `FieldBox` uses the existing boundary-aware `onArrowLeft` (cursor-at-start → exit to nav).
- `Tab`/`⇧Tab` — walk every stop including the per-row reset icon (control → reset → next control).
  This is where Layout diverges from Keybinds (which reaches reset via `→`, since its record
  buttons don't claim `←/→`). Same reset behavior, different reach key, because sliders/fields own
  `←/→`. `AppButton` already consumes `Tab` (added in PR1); the section routes it through the row.
- `Esc` — close (every control routes `onEsc` → `onClose`, as in Keybinds).

## Live re-apply seam (contained hooks)

- **`reduce-motion`:** the existing `AppDelegate` `configDidChange` observer additionally calls
  `MotionConfig.apply(GeneralConfig.current.reduceMotion)`. `MotionConfig.apply` is idempotent and
  global; the animation primitives already read its closure live. One line.
- **`backdrop-alpha` / `window-gutter` / `pane-gap`:** a new `configDidChange` observer on
  `WindowController` that:
  - stores the backdrop `tint` view (today a local `let` in setup) and re-sets its layer color
    from `backdropAlpha`;
  - stores the four window-gutter content-inset constraints and updates their `.constant` from
    `windowGutter`, then `layoutSubtreeIfNeeded`;
  - re-runs `relayoutPanels()` (promoted `private` → `internal`) so `panelGap` re-tiles.
  Observer is added per `WindowController` and removed in `tearDown()` (no dangling observer after
  a window closes).
- **Drawer fractions / shell:** no hook (new-tab-only by design).

## Files

**New:**
- `Sources/ZenTerm/Controls/Slider.swift` — shared bounded-scalar slider primitive.
- `Sources/ZenTerm/SettingsLayoutSection.swift` — the section editor.
- `Sources/ZenTerm/LayoutRow.swift` — a scalar-editing row (caption · control · reset · message).
- `Tests/ZenTermTests/SliderTests.swift` — clamp/quantize/nudge logic (pure).
- `Tests/ZenTermTests/LayoutValueTests.swift` — value ↔ config-string round-trip + `isOverridden`
  + reset-is-removal, via `ConfigWriter` to a temp `configRoot` (mirrors `ConfigWriterTests`).

**Modified:**
- `Sources/ZenTerm/WindowController.swift` — register `SettingsLayoutSection`; add the
  `configDidChange` observer + stored `tint`/gutter-constraint refs + observer teardown; promote
  `relayoutPanels()` to `internal`.
- `Sources/ZenTerm/AppDelegate.swift` — the config observer also re-applies `MotionConfig`.
- `docs/config/config` — per-knob live-apply notes (which apply live vs. new tabs).

**Untouched:** `SettingsOverlay`, `SettingsSection`, `SettingsKeybindsSection`, `ConfigWriter`
(consumed as-is), the palette scaffold.

## Testing

**Unit:**
- `SliderTests`: value clamps to range; nudging by `step` quantizes and clamps at both ends; a
  value off the step grid snaps predictably.
- `LayoutValueTests`: each field's value renders to the expected config string and re-parses equal
  (floats, `reduce-motion` enum, `shell-args` join/split); writing then reading via `ConfigWriter`
  round-trips; a reset (`removals`) drops the key so the parser returns `builtIn`; `isOverridden`
  is false at default and true after an edit.
- `bin/check` fully green (build + tests + `swift format lint --strict` + `swiftlint --strict`).

**Manual runbook (`swift run ZenTerm`):**
- ⌘, → Settings → Layout & Motion appears as the second nav entry; arrow into it.
- **Live knobs:** drag backdrop-alpha → the current window's modal backdrop re-tints immediately;
  bump window-gutter / pane-gap → the current window's panes re-tile; set reduce-motion On → the
  next card open/close has no spring. `cat ~/.config/zen-term/config` shows the new values with
  surrounding comments intact.
- **New-tab knobs:** change bottom/right-drawer-fraction and shell → the current tab is unchanged;
  open a new tab (⌘T) → it uses the new fractions / shell. A hand ⌥-resized drawer keeps its size.
- **Reset:** per-row reset icon appears once a knob differs from default; clicking (or Tab-to +
  Return) reverts the value live and removes the key from the file. Reset-all reverts every knob.
- **Keyboard:** ↑/↓ move rows; ←/→ nudge a focused slider / move a field cursor; Tab reaches the
  reset icon; Esc closes from any control.

## Out of scope (explicit)

- Terminal appearance + Theme sections (ZEN-75 PR3).
- Forcing running drawer ratios or running shells to retro-apply (runtime/OS-owned).
- Advanced `shell-args` quoting UI (single joined field in v1; the file supports the rest).
- A file-watcher for external hand-edits (ZEN-80).
