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
| `background` | The window and every surface on it except a float, which takes its tier's raised fill. See [Elevation](#elevation) |
| `foreground` | The base every ink and fill is derived from |
| `accent` | Pane focus, the primary action, loading. See [Accent](#accent) |
| `onAccent` | Text and rings on an accent fill, and nowhere else. The background or the foreground, whichever contrasts more with `accent` |
| `working` | An agent mid-turn. ANSI yellow, whatever the accent |
| `done` | An agent that finished its turn, on its Agents row and its tab. ANSI blue, whatever the accent |
| `blocked` | An agent asking for approval. ANSI red, whatever the accent |
| `positive` | Success, completed, kept |
| `warning` | Caution: proceeding has a cost |
| `destructive` | Loss, deletion, errors |
| `info` | A neutral notice |
| `cursor` | The accent, painted onto the terminal cursor too, and chrome that marks where the cursor or focus will land |

Agent state roles are their own and never borrow `info`, `positive`, `warning` or `destructive`.

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
  with `ChromeTheme.hairline`, `.border`, `.divider` (the toolbar's group dividers) or `.swatchRing`.
- **A role-toned surface behind text** takes `chrome.tint(_:alpha:)` with `ChromeTheme.badgeTint`
  or `.flashTint`. It sits outside the per-theme fill scale, so it never goes next to a
  sibling `fill(_:)`.

### Accent

Accent is rare. It goes in these places only:

- The focus border of a pane while another pane or drawer shares the screen, and a shortcut being recorded.
- The primary button's fill, labeled and ringed in `onAccent`.
- Loading: `Spinner` and the update progress bar. An agent's spinner takes `working` instead.
- The live `StateDot`: a toolbar button's background dot and the workspace form's opens-focused tab.
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
- The exceptions are the shadow's black in `FloatShadow`, whose strength is solved per
  theme, the white a light theme's raised fill lifts toward, and a process chip's brand
  colors (below). Any other theme-independent value (an alpha mask) carries a one-line why.

### Process chips

A process chip (`IconBadge(process:size:)`) is a small app icon for what runs in a pane. A
brand's fill and glyph colors belong to the brand, not the theme, so they stay the same on
every theme. They live in `ProcessIcon`'s registry and nowhere else; no call site names
one. Everything else comes from the system: the shape (`Radius.icon(_:)`, continuous
corners), the size and mark box (`IconBadge.Size`), the edge (`fill(alpha:)` with `border`,
at `Border.width`) and the sheen (`ChipSheen`), a fixed alpha mask lit from the top that every chip shares, and an SSH host's emblem tile in a longer, lighter spread.
A chip with no brand (a shell, a generic program, a worktree) takes `chipRaised`, a lift a
step above the floats solved like the raised fills, and `ink(.normal)`. Brand color means a
program runs, so a resting shell and a worktree are never branded. A purpose tint names a
palette group: a soft `tint(_:alpha:)` of an ANSI hue at `badgeTint` over `chipRaised`, behind
the glyph in full hue (`ProcessIcon.Look.purpose`). ANSI red is never a purpose tint: it is
`blocked`. Process marks are never SF
Symbols, except a tool float's own icon in its palette row (`ProcessIcon.toolFloat`), which is
an icon picker name; a generic chip's glyph is Lucide, unmodified. In a row, a chip leads it
(`ListRow.Leading.process`, at `.small`): an Agents row, a worktree row in the sidebar, and a
palette row.

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

In a transient list, hover moves the keyboard cursor, so one row is lit at a time and ↑/↓
continue from the row the pointer chose. A persistent list shows keyboard focus as the ring,
and hover does not move it. In every row list a row activates on mouse up, and ↑/↓ stop at
the ends. Focus changes a border's color, never its width. The one exception is the focus
halo: the focused pane or drawer steps up to `Border.paneFocus` in accent only while another pane
or drawer shares the screen. Nothing else wears it, so a lone or zoomed pane, a float and the SSH
Connect screen show none.

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
place). A section heading or field caption is a `SectionCaption`, in sentence case.

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
| `Radius.icon(_:)` | A process chip's app-icon corner, from its side |
| `Border.width` | Every border, edge and focus ring |
| `Border.paneFocus` | A focused pane |
| `Icon.xs`, `.sm`, `.md`, `.xl` | SF Symbol point sizes |

`panelGap`, `windowGutter` and `footerGap` are window layout, set from config,
not design tokens.

A `Width`, `Size`, `Side`, `Thickness`, `Length` or `Diameter` name is for a true shape
dimension only. A drawing proportion that is not chrome takes
`// swiftlint:disable:next <rule>`.

## Elevation

Every float has a 1pt `FloatShadow.edge`, a shadow tier applied with
`FloatShadow.apply(_:to:)`, and its tier's raised fill, `chrome.raised(_:)`. `CardChrome`
applies all three. Never build an `NSShadow` by hand, and never paint a float `background`.

The raised fill steps the window color lighter by the tier's `lightening` in L\*, solved per
theme in `ChromeThemeDeriver`: toward the foreground on a dark theme, toward white on a light one,
clamping where there is no room left. A dark float stops halfway to its ink, so text on it stays legible. The overlay lifts most, since it opens on other floats. A
tool float's terminal host keeps the terminal background.

| Tier | For |
|---|---|
| `.overlay` | Anything anchored: popovers, dropdowns, tooltips, hover cards |
| `.float` | Toasts, cards, the floating sidebar, tool floats |
| `.modal` | Modals. `CardChrome`'s default |

A drawn shadow (one outside a see-through card) reads `FloatShadow.color(_:)` and the
tier's `contextBlur` and `offset`.

## Motion

Animation goes through `Motion`. Its helpers check Reduce Motion themselves, except
`drawerSlide`, whose callers do. Under Reduce Motion a completion runs synchronously, except
`slideFade`'s and `handOff`'s, which still fade.

| Token or helper | For |
|---|---|
| `fadeDuration` | Fades in and out |
| `entranceFadeDuration` | The fade on a surface's entrance |
| `pageSlideDuration` | Page and canvas slides |
| `hoverIntent` | The delay before a tooltip or hover card shows |
| `Linger.ack`, `.readout`, `.notice`, `.toast` | How long a confirmation, a readout, a notice and a toast stay on screen |
| `springScaleFade` | Modals, toasts and floats appearing and leaving |
| `fade` | Plain opacity changes, tooltips and the link preview |
| `crossfade` | A process chip swapping its mark when its program changes; with `whenReduced`, a dissolve that stands in for movement |
| `HostConnect` | The SSH host Connect screen's choreography: the emblem's rain and answer, the words after it, and the hand-off to the terminal |
| `ease` | A hover fill or color change |
| `stretch` | The selection pill sliding between tabs |
| `slideSwap` | Switching workspaces |
| `handOff` | An SSH host's Connect screen giving way to its terminal |
| `slideFade` | The collapsed sidebar's hover reveal, the find bar and the mode header |
| `drawerSlide` | Drawers and docking the sidebar |
| `zoomPop` | Focus Mode |

Debounces, polls and timeouts are not motion; they stay with their owner.

## Components

Tokens live in `Sources/ZenTerm/Tokens/`, and shared components in `Sources/ZenTerm/UI/`.
Neither depends on a feature or on `App/`. The dev build's Component Gallery is the
catalog: it shows every shared component and its states.

A control's hover and eased fill come from `ControlView`, or from `ControlState` on a control that
cannot subclass it (`AppButton`). A control never keeps its own tracking area. A control on that base
takes keyboard focus and its ring from it too.

A row in a list is a `ListRow`: popover lists, menus, palettes (`SelectableRowView`), Settings lists, the Settings and sidebar nav (`NavRow`), and the sidebar's agent rows (`SidebarJumpRow`). A word about the row's state rides right after its title in muted caption ink (`ListRow.Content.titleSuffix`: the picker's Current, Open, Other window); a `note` sits at the trailing edge.

The command palette and the workspace picker share one shell, `PaletteOverlay`: its top pinned where it would center at its full height, so only its bottom moves with the results, and a search field. A command palette row leads with a process chip (`ListRow.Leading.process`) in its group's purpose tint; a workspace picker row's icon is plain (`ListRow.Leading.symbol`). A row's detail (the picker's branch, the palette's category while a query filters out the headers) sits in muted ink just left of its shortcut. Every header but the list's first leaves `PaletteSectionHeader.sectionGap` above it. The bar names the selected row's Return action and the shortcuts that act on it, never ↑↓ or esc.

A dot is a `StateDot`: blocked reads `blocked`, done `done`, idle muted ink, live `accent`, online (an SSH host's Connect screen) `positive`. It is never a ring. An Agents row centers its chip, dot or spinner on the title's line, and its workspace line starts with the title's text (`ListRow.Content.leadingOnTitleLine`). A nested Agents row's chip starts there too (`ListRow.Nesting.underTitle`).

A boxed input (a text field, a text area, a picker) takes its rest fill and border from `FieldChrome`.

A form or row's message line is a `FormErrorLabel`, in its destructive, warning or muted tone.

A centered message that wraps is a `BalancedLabel`: its lines come out of similar width, and it never truncates.

A mark on a rounded chip is an `IconBadge`: tinted by one role, or a process chip (see
[Process chips](#process-chips)).

A modal's title row is `ModalHeader` and its button row is `ModalActionBar`; a keyboard-only card uses
`HintFooter` in its place: right aligned, each hint its Title Case label then its key. The shared hairline rule is `Divider`, and the shared muted "nothing here"
line is `EmptyStateLabel`.

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
