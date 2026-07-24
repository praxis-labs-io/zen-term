# Swift / AppKit conventions

Hard-won conventions for the chrome, past what a linter or the type checker catches. These are the
traps that shipped a real bug (or nearly did) and cost real debugging time. Read this before
touching window sizing, event routing, layers, or interaction tests; add to it when a new one bites,
with the symptom, the rule, and the ticket.

The canonical statement of the testing rules lives in `CLAUDE.md` ("Test what can be silently
dead"); this doc holds the AppKit-specific corollaries and the implementation traps.

## Windows and modals

**A resizable window must set an explicit `contentMinSize`.** Without one, AppKit derives the
window's size range from its content Auto Layout constraints. Every modal card sizes itself
proportionally to its container (e.g. `card.width <= container.width * 0.92`), which is satisfiable
down to near-zero, so *mounting a modal collapsed the derived minimum and the window got clamped
small until the modal closed*. This is the "windows get resized by modals" bug. Pin the floor once
on the window and it is decoupled from any present or future overlay:

```swift
contentMinSize = NSSize(width: 480, height: 320)  // HostWindow.init (ZEN-226)
```

## Event routing and the responder chain

**Custom menu-action selectors are resolved by the responder chain, and the window delegate is
reached before the app delegate.** A menu item with a nil target sends its action via
`NSApp.targetForAction`, which walks: firstResponder up its chain, the window, the *window's
delegate*, the window controller, `NSApp`, then `NSApp`'s delegate. `WindowController` is the window
delegate, so it is found and invoked ahead of `AppDelegate`, and the search stops there. Any
conditional routing (e.g. "when a modal card is up, send copy/paste to the focused field instead of
the terminal") must live on the responder that is actually reached first. A copy of the same guard
in `AppDelegate` is dead code that never runs (ZEN-235). The terminal surface controllers
(`PaneCanvasController`, `TabController`) are plain `NSObject`, never real responders in that chain,
so they are only ever reached through `WindowController`'s own manual dispatch.

**Never present a sheet inside `mouseDown`.** `NSOpenPanel` / `NSSavePanel` / `NSAlert`'s
`beginSheetModal(for:)` called synchronously within a `mouseDown` dispatch, before the matching
`mouseUp`, is silently dropped by AppKit: the sheet never attaches, nothing appears, no error.
Present from a control's action instead (an `NSButton`/`AppButton` fires on `mouseUp` via
`sendAction`), or defer to the next runloop turn. This is why the directory picker moved from a
click-on-the-empty-field affordance to an explicit Choose button (ZEN-235).

**Synthesized `NSEvent`s must match what AppKit actually delivers.** Every arrow `keyDown` carries
`.function` *and* `.numericPad` on top of the modifier you care about, so comparing against
`.deviceIndependentFlagsMask` (which keeps those bits) never equals a bare modifier. Match against
the reservable set instead: `flags.intersection([.command, .shift, .option, .control])`. A
synthesized `modifierFlags: .option` event is a keystroke macOS never sends: it shipped a dead
⌥-arrow reorder past four green tests and a mutation check, because both only ever exercised the fake
event (ZEN-145).

## Scroll views

**A single-column `NSOutlineView` left at the default `.automatic` style is permanently wider than
its clip.** `.automatic` resolves to the inset/source-list family, whose tiling reserves a constant
**+32pt in the outline's own frame beyond the column width**, and reports `intercellSpacing` as
`(17, 0)` — not the classic `(3, 2)` most code assumes. So an outline sized to fill its clip with the
documented formula (`column.width = clipWidth - intercellSpacing.width`) still leaves the document
~15pt wider than the clip at *every* width, independent of row content — a static geometry overflow,
not a scroll artifact, so a `constrainBoundsRect` origin-clamp and `horizontalScrollElasticity = .none`
defend against dragging into it but never remove it. Force `outline.style = .plain` and zero the
intercell width (`intercellSpacing = NSSize(width: 0, height: intercellSpacing.height)`); `.plain`
restores the real `documentWidth = columnWidth + intercellSpacing.width` relation, making the fill
math exact. `.plain` also stops silently overriding `rowSizeStyle` (row height drops 24→17 for
`.small`). `.plain` draws level-0 rows hard against the column edge, so a section header's disclosure
triangle pokes left of a selection pill: shift level-0 cells right by one `indentationPerLevel` in
`frameOfOutlineCell`/`frameOfCell` to seat them inside the pill (ZEN-236).

**`NSTableView` shares the same `.automatic` inset trap.** Left at the default style, a plain
`NSTableView` reserves a source-list-style horizontal row inset, so its rows — and any full-row
selection or background — sit off the pane's leading and trailing edges by a fixed margin you never
asked for. The diff pane read as gapped from the tree divider on the left and the card edge on the
right until `table.style = .plain` removed it. Once it's `.plain`, add whatever margin you *do* want
explicitly (a leading/trailing constant on the table, or the row content's own insets) so the amount
is yours, not the framework's — and a full-row pill takes no extra inset of its own on top of that
margin, or it nests a second gap inside the first (ZEN-243).

**`NSScrollView.contentInsets` is scrollable range, not padding.** A nonzero inset on an edge
extends the clip view's pannable range by exactly that many points on that edge — same model as
`UIScrollView.contentInset` — *even when the document view exactly fills the clip on that axis*. A
single-column `NSOutlineView` sized to fill its clip's width exactly still scrolled sideways by a
fixed few points at every window width because `contentInsets.left`/`.right` were nonzero (wanted
for visual breathing room); no amount of recomputing the column's width against
`contentView.bounds` could cancel it, because the pannable range is additive on top of the
document/clip width relationship, not derived from it. Reserve `contentInsets` for axes that are
actually meant to scroll (e.g. `top`/`bottom` breathing room above/below the first/last row); get
edge padding on a non-scrolling axis from the row content's own insets instead (`DiffTreeRowView`,
`DiffTreeOutlineController.swift`), which affect where content draws/truncates, never the
document's reported frame width (ZEN-226).

## Auto Layout, resize, and text sizing

**A width-responsive relayout must key off a frame-change notification, not a child's `bounds` read
inside `layout()`.** AppKit resolves a view's own frame before its `layout()` runs, but a *descendant*
(an `NSScrollView`'s document, a table tiling its rows) gets its new frame *after* the ancestor's
`layout()` returns — so reading `table.bounds.width` from the enclosing view's `layout()` sees the
*previous* width on a live window resize. It looks correct in a unit test only because
`layoutSubtreeIfNeeded()` flushes the whole subtree first, which the app's incremental passes don't.
For "do X when this view's width crosses a threshold," observe the view itself:
`view.postsFrameChangedNotifications = true` + `NSView.frameDidChangeNotification`, which fires with
the *final* frame on every resize and on first layout. The diff viewer's auto-fold was dead in the app
(green in tests) until it moved off a `layout()` width read onto the pane's frame notification
(ZEN-243).

**An `NSTextField` label sized to the exact glyph advances truncates to `…`.** A label insets its text
a couple of points inside its frame, so a column sized to `characters * digitWidth` is a hair too
narrow and clips even a single digit. Size a content-fit label to its string plus a few points of
padding (`DiffCellMetrics.numberColumnWidth`), or measure the actual string with the label's own
attributes and pad — never the raw advance sum (ZEN-243).

**A non-truncating label holds its container — and the window — open.** A label defaults to a high
horizontal compression resistance and no truncation, so its intrinsic width becomes a hard floor for
everything it's pinned inside. A long value (a footer showing the full branch name) propagated up
through the card's proportional width constraint and *stopped the window from reaching its own
`contentMinSize`*. For any label that should yield when space is tight, set a truncating
`lineBreakMode` **and** lower its horizontal compression resistance
(`setContentCompressionResistancePriority(.defaultLow, for: .horizontal)`) — setting it on the
enclosing `NSStackView` is not enough; the child label resists on its own (ZEN-243).

**A custom `NSView` with no `intrinsicContentSize` cannot resist stretching in a stack, at any
priority.** Content-hugging and compression-resistance only install their constraints on an axis where
`intrinsicContentSize` returns a real value. A view sized purely by its own internal constraints (a
`KeycapView`: an inner token stack pinned leading/trailing + a height constant) returns
`noIntrinsicMetric`, so `setContentHuggingPriority(.required, …)` **on that view** is a silent no-op —
there is nothing for the priority to attach to. Inside an `NSStackView` (default `.fill` distribution)
it is then the only elastic member and absorbs every point of slack: a one-glyph keycap stretched into
a wide pill, because the neighboring `NSTextField` ships with horizontal hugging 251 — one above the
keycap's transitively-inherited 250 — and wins the tie for who does *not* stretch. Override
`intrinsicContentSize` to report the width the view's own constraints already produce
(`tokenStack.fittingSize.width + insets`), and `invalidateIntrinsicContentSize()` when its content
changes; only then do hugging/compression priorities engage. Setting those priorities at the call site
is correct code aimed at nothing until the view itself reports an intrinsic size (ZEN-262).

**A label's `lineBreakMode` governs `stringValue` only; an attributed string carries its own.** Set
`attributedStringValue` and the label's `lineBreakMode`, `alignment` and `font` stop applying: the
string's attributes win, and any attribute you leave out falls back to the system default rather than
to the label's setting. The default `NSParagraphStyle` wraps (`.byWordWrapping`), so an attributed
line in a label with `maximumNumberOfLines = 1` draws only its first wrapped line and silently loses
whole words off the end. That is far more destructive than the `.byClipping` the label declared, which
would merely cut mid-glyph. Whenever a view can render either a plain or an attributed string, put
every layout-affecting attribute (paragraph style and font) on the attributed string so both paths
behave alike (`SyntaxAttributedText`). The diff viewer shipped this: highlighted lines rendered
`] as const;` as `] as`, and short lines vanished entirely, while the same diff was complete before
highlighting existed (ZEN-239).

**Asserting a label's frame width does not prove its text is drawn.** The bug above passed every test,
including window-based ones through the real table, because they measured `frame.width` against the
string's measured width and those matched. The frame was never wrong; the *drawing* was. For text that
must appear in full, assert the property that governs drawing (here the paragraph style's
`lineBreakMode`), not the geometry around it (ZEN-239).

## Layers, shadows, and colors

**Static layer shadows go on `NSView.shadow`, not `layer.shadowOpacity`.** Setting
`layer.shadowOpacity` on a layer-backed view *before it joins a window* does not stick: inserting a
subtree (an overlay containing a card) makes AppKit re-realize the backing layers and re-sync
`NSView.shadow == nil` to `layer.shadowOpacity = 0` (radius/offset/color survive, so it looks
half-configured). Use `NSView.shadow = NSShadow(...)` for static shadows (survives the re-sync,
combines fine with an explicit `layer.shadowPath`). Direct `layer.shadow*` writes are only safe
*after* insertion, which is why animated focus glows driven post-mount work (ZEN-54).

**A layer-*hosting* view owns its own `contentsScale`, and screen moves need their own
notification.** AppKit syncs `layer.contentsScale` to the window's backing scale factor only for
layer-*backed* views. `GhosttyHostView` is layer-hosting (libghostty attaches its Metal layer, so the
view must never set `wantsLayer`), so nothing updates it for us and the renderer keeps sizing its
drawable at the scale it was born with: text on a window dragged to a display of a different density
stays at the old pixel density, rescaled by the compositor. Set it in
`viewDidChangeBackingProperties` inside a `CATransaction` with `setDisableActions(true)` (otherwise
Core Animation animates the scale change and it reads as jank). AppKit also does not reliably deliver
that callback on a screen move, so observe `NSWindow.didChangeScreenNotification` and re-run the same
path on the next main-loop turn: the window's `backingScaleFactor` is not updated yet when the
notification lands (ZEN-247, ghostty-org/ghostty#2731).

**Never hardcode a color, and remember that system-derived colors count.** They do not look like
colors but they resolve against the view's `effectiveAppearance`, not `Theme.current`, so they wash
out on light themes: `NSTextField.placeholderString` (renders in the system `placeholderTextColor`),
`NSColor.secondaryLabelColor` / `.labelColor` / `.controlTextColor` / `.placeholderTextColor`,
`NSColor(white:)`. Use theme-derived values: for placeholders, a `placeholderAttributedString`
colored from a `ChromeTheme` role. See the Colors section in `CLAUDE.md` (ZEN-27, ZEN-89).

## Process-global state

**Release process-global macOS state on focus / app-active changes, not on surface teardown.** The
chrome detaches persistent surfaces with `removeFromSuperview` without calling `terminate()`/`deinit`,
so tying release to teardown leaks the global lock when a pane is merely hidden. Secure keyboard
entry (`EnableSecureEventInput`) left engaged after you Cmd-Tab away from a `sudo` prompt suppresses
keyboard input system-wide in other apps. Scope such state to the *focused* surface and tie it to
`NSApplication.didResignActive` / `didBecomeActive` (ZEN-72).

## Testing AppKit

**AppKit controls get window-based interaction tests, not state-only tests.** A test that only reads
the backing view-model passes while the control is dead: that is exactly how a fully broken dropdown
shipped past two reviews. Drive the real control in a real window. "Mounted + focused" is the same
trap one layer up: `superview` membership says nothing about paint order, so a view buried behind a
sibling passes every reasonable-looking assertion. For layered views (float cards, overlays,
toasts), assert the subview index relative to what it must cover (ZEN-141).

**Synthetic mouse events are not hit-tested to a view in a headless / off-screen window.**
`window.sendEvent(mouseDown/Up)` will not route to a target view when the window is not real and key,
and making it real and key orders it on screen (flashing UI in the test run, and any presented panel
along with it). So a click cannot be routed through the scroll/clip view to a control in a unit test.
Drive the control's `mouseDown` / `mouseUp` handlers directly with real `NSEvent`s (that still
exercises the control's own logic, not its backing state); leave "a real click at that point reaches
the control through the view tree" to a runbook step. Corollary to ZEN-145 (ZEN-235).

**Tests must not mutate real OS state.** They run on the developer's machine. Do not clobber
`NSPasteboard.general` (snapshot it in `setUp`, restore in `tearDown`), and do not present a real
`NSOpenPanel` (inject a present-panel seam so the test asserts the wiring without a sheet). Both leak
into the machine on every `swift test` otherwise (ZEN-235). Same spirit as the "tests must not read
real user config" rule.
