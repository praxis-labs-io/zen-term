# Design system

The chrome's tokens and the rules for using them. The code is the source of truth: when
this doc and the code disagree, the code wins and this doc gets fixed. A design board is
a sketch of an idea, never a spec: map it onto these tokens and primitives, never copy a
value off it. Values live in the token files, so this doc names tokens and never repeats
a number.

## Color

Everything in the chrome resolves from `Theme.current`. Chrome UI takes
`Theme.current.chrome` (`ChromeTheme`); a terminal surface takes
`TerminalSurfaceConfig(theme: Theme.current.terminal)`.

### Roles

| Role | Means |
|---|---|
| `background` | The window and every surface on it |
| `foreground` | The base every ink and fill is derived from |
| `accent` | Pane focus, the primary action, work in progress. See [Accent](#accent) |
| `onAccent` | Text and rings on an accent fill, and nowhere else. The background or the foreground, whichever contrasts more with `accent` |
| `attention` | Something is waiting on the user |
| `positive` | Success, completed, kept |
| `warning` | Caution: proceeding has a cost |
| `destructive` | Loss, deletion, errors |
| `info` | A neutral notice |
| `cursor` | The terminal cursor's color, and chrome that marks where the cursor or focus will land |

A role the chrome needs and `ChromeTheme` lacks gets added to `ChromeTheme` and derived
in `ChromeThemeDeriver`. Never a literal.

### Ink

Text and icons take `chrome.ink(_:)`, never an alpha. Four weights, no fifth:

| Weight | For |
|---|---|
| `.normal` | Active or hovered: body text, a current item, a hovered control |
| `.subtle` | A control at rest: a toolbar icon, an inactive tab, a secondary button label |
| `.muted` | What recedes: captions, hints, counts, placeholders, section labels |
| `.faint` | Quieter than what it sits beside: a disabled label, a hint opposite a caption |

A site that wants a weight between two of these has too many tiers.

### Fills

Three ways in, never a raw alpha:

- **A control's interactive states** take a tier, `chrome.fill(.rest / .hover / .active)`.
- **Structural fills** (a divider, a border, a swatch ring) take `chrome.fill(alpha:)`
  with `ChromeTheme.hairline`, `.border` or `.swatchRing`.
- **A role-toned surface behind text** takes `chrome.tint(_:alpha:)` with `ChromeTheme.badgeTint`
  or `.flashTint`. It sits outside the per-theme fill scale, so it never goes next to a
  sibling `fill(_:)`.

### Accent

Accent is rare. It goes in these places only:

- The focus border of a pane or tool float, and a shortcut being recorded.
- The primary button's fill, labeled and ringed in `onAccent`.
- Work in progress: the working dot, `Spinner`, the update progress bar.
- Role-toned `tint` surfaces: icon badges, focused text selection, the find bar, the
  scroll flash.

A control's focus or edit ring takes `chrome.focusRing`, a neutral. Never accent text, an
accent check mark, an accent selection or state fill, or `accent.withAlphaComponent`.

### Banned

`NSColor(white:)`, `.white`, `.black`, raw hex, literal palette values, and AppKit
system and semantic colors (`.secondaryLabelColor`, `.placeholderTextColor`, a text
field's default placeholder tint, a field editor's default caret and selection). They
follow the macOS appearance, not the theme.

- Text fields edit through `ChromeTextView`, which `HostWindow` vends as the field
  editor; a field calls `applyThemedEditor()` on a theme change.
- The one exception is the shadow's black in `FloatShadow`, whose strength is solved per
  theme. Any other theme-independent value (an alpha mask) carries a one-line why.

## State

One ladder for every control and row:

| State | Rule |
|---|---|
| Rest | Rows clear. Fields, keycaps and filled buttons `fill(.rest)`. Text `ink(.normal)`, controls `ink(.subtle)` |
| Hover | `fill(.hover)` |
| Keyboard cursor | `fill(.hover)`. In a transient list (palette, dropdown, menu) the cursor is the focus |
| Focused | A `focusRing` ring at `Border.width`. Fill and ink unchanged. On the primary button the ring is `onAccent`, inset by `Border.width` |
| Current | Pick lists: a check mark only. Persistent nav, tabs and segments: `fill(.active)` |
| Pressed | Looks like hover |
| Disabled | `ink(.faint)` on every variant. Controls keep `fill(.rest)`; no hover, no ring |

A persistent list shows keyboard focus as the ring, and hover does not move it. Focus
changes a border's color, never its width; a focused pane or tool float steps up to
`Border.paneFocus`.

## Type

Fonts come from `ChromeType.font(_:weight:face:)`, never `systemFont(ofSize:)`.

| Role | For |
|---|---|
| `display` | The largest heading on a surface |
| `title` | A card, modal or section title |
| `body` | Default text |
| `small` | Secondary text and button labels |
| `caption` | Details, notes, counts |

Weights are `.regular`, `.medium` and `.semibold`; each role has a default. Faces are
`.text`, `.mono` (code, commands, paths, keycaps) and `.digits` (numbers that change in
place). A section heading takes `ChromeType.sectionLabel`, in sentence case.

## Space and shape

All in `ChromeMetrics`. A size is one token, never arithmetic on tokens. Layout math that
combines measurements stays, with each term named. A value off a scale means the layout
needs fixing, not a new step.

| Token | For |
|---|---|
| `Spacing.s2` to `Spacing.s32` | Gaps, insets, padding |
| `Spacing.controlInset` | A control's horizontal padding |
| `Spacing.modalInsets`, `Spacing.modalSectionGap` | A modal's padding and the gap between its sections |
| `Height.xs`, `.sm`, `.control`, `.lg`, `.xl` | Control and row heights. `.control` is the standard control or row |
| `Radius.control` | Controls and rows |
| `Radius.surface` | Cards, popovers, floats |
| `Radius.tile` | Large tiles |
| `Radius.capsule(_:)` | A fully rounded end, from the view's height |
| `Border.width` | Every border, edge and focus ring |
| `Border.paneFocus` | A focused pane or tool float |
| `Icon.xs`, `.sm`, `.md`, `.xl` | SF Symbol point sizes |

`panelGap`, `windowGutter`, `topInset` and `footerGap` are window layout, set from config,
not design tokens.

A `Width`, `Size`, `Side`, `Thickness`, `Length` or `Diameter` name is for a true shape
dimension only. A drawing proportion that is not chrome takes
`// swiftlint:disable:next <rule>`.

## Elevation

Every float has a 1pt `FloatShadow.edge` and a shadow tier, applied with
`FloatShadow.apply(_:to:)`. Never build an `NSShadow` by hand.

| Tier | For |
|---|---|
| `.overlay` | Anything anchored: popovers, dropdowns, tooltips, hover cards |
| `.float` | Toasts, cards, the floating sidebar, tool floats |
| `.modal` | Modals. `CardChrome`'s default |

A drawn shadow (one outside a see-through card) reads `FloatShadow.color(_:)` and the
tier's `contextBlur` and `offset`.

## Motion

Animation goes through `Motion`. Its helpers check Reduce Motion themselves, except
`drawerSlide`, whose callers do. Under Reduce Motion a completion runs synchronously.

| Token or helper | For |
|---|---|
| `fadeDuration` | Fades in and out |
| `entranceFadeDuration` | The fade on a surface's entrance |
| `pageSlideDuration` | Page and canvas slides |
| `hoverIntent` | The delay before a tooltip or hover card shows |
| `Linger.ack`, `.readout`, `.notice`, `.toast` | How long a confirmation, a readout, a notice and a toast stay on screen |
| `springScaleFade` | Modals, toasts and floats appearing and leaving |
| `fade` | Plain opacity changes |
| `ease` | A hover fill or color change |
| `stretch` | The selection pill sliding between tabs |
| `slideSwap` | Switching workspaces |
| `slideFade` | The collapsed sidebar's hover reveal |
| `drawerSlide` | Drawers and docking the sidebar |
| `zoomPop` | Focus Mode |

Debounces, polls and timeouts are not motion; they stay with their owner.

## Components

Tokens live in `Sources/ZenTerm/Tokens/`, and shared components in `Sources/ZenTerm/UI/`.
Neither depends on a feature or on `App/`. The dev build's Component Gallery is the
catalog: it shows every shared component and its states.

A modal's title row is `ModalHeader` and its button row is `ModalActionBar`; a keyboard-only card uses
`HintFooter` in its place.

## Extending the system

Ask before adding a role, a token, a tier or a primitive. A new role is derived in
`ChromeThemeDeriver`; a new token goes in its token file; a new primitive goes in
`UI/` and shows its states in the Component Gallery.

## Enforcement

`bin/check` runs `swiftlint --strict`, which fails on:

| Rule | Rejects |
|---|---|
| `untokened_font` | `systemFont(ofSize:)` outside `ChromeType` |
| `untokened_icon_size` | A literal symbol point size |
| `untokened_radius` | A literal radius, border width or line width |
| `untokened_spacing`, `untokened_spacing_constant` | A literal spacing, inset, padding, gap or height |
| `unfaded_scroll_view` | `NSScrollView(`: scroll areas use `FadingScrollView` |

Color, shadow and motion have no lint; review holds them.
