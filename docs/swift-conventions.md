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
`(17, 0)`, not the classic `(3, 2)` most code assumes. So an outline sized to fill its clip with the
documented formula (`column.width = clipWidth - intercellSpacing.width`) still leaves the document
~15pt wider than the clip at *every* width, independent of row content: a static geometry overflow,
not a scroll artifact, so a `constrainBoundsRect` origin-clamp and `horizontalScrollElasticity = .none`
defend against dragging into it but never remove it. Force `outline.style = .plain` and zero the
intercell width (`intercellSpacing = NSSize(width: 0, height: intercellSpacing.height)`); `.plain`
restores the real `documentWidth = columnWidth + intercellSpacing.width` relation, making the fill
math exact. `.plain` also stops silently overriding `rowSizeStyle` (row height drops 24→17 for
`.small`). `.plain` draws level-0 rows hard against the column edge, so a section header's disclosure
triangle pokes left of a selection pill: shift level-0 cells right by one `indentationPerLevel` in
`frameOfOutlineCell`/`frameOfCell` to seat them inside the pill (ZEN-236).

**`NSTableView` shares the same `.automatic` inset trap.** Left at the default style, a plain
`NSTableView` reserves a source-list-style horizontal row inset, so its rows, and any full-row
selection or background, sit off the pane's leading and trailing edges by a fixed margin you never
asked for. The diff pane read as gapped from the tree divider on the left and the card edge on the
right until `table.style = .plain` removed it. Once it's `.plain`, add whatever margin you *do* want
explicitly (a leading/trailing constant on the table, or the row content's own insets) so the amount
is yours, not the framework's, and a full-row pill takes no extra inset of its own on top of that
margin, or it nests a second gap inside the first (ZEN-243).

**`NSScrollView.contentInsets` is scrollable range, not padding.** A nonzero inset on an edge
extends the clip view's pannable range by exactly that many points on that edge, the same model as
`UIScrollView.contentInset`, *even when the document view exactly fills the clip on that axis*. A
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
`layout()` returns, so reading `table.bounds.width` from the enclosing view's `layout()` sees the
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
attributes and pad, never the raw advance sum (ZEN-243).

**A non-truncating label holds its container, and the window, open.** A label defaults to a high
horizontal compression resistance and no truncation, so its intrinsic width becomes a hard floor for
everything it's pinned inside. A long value (a footer showing the full branch name) propagated up
through the card's proportional width constraint and *stopped the window from reaching its own
`contentMinSize`*. For any label that should yield when space is tight, set a truncating
`lineBreakMode` **and** lower its horizontal compression resistance
(`setContentCompressionResistancePriority(.defaultLow, for: .horizontal)`) fixes it; setting it on the
enclosing `NSStackView` is not enough; the child label resists on its own (ZEN-243).

**A custom `NSView` with no `intrinsicContentSize` cannot resist stretching in a stack, at any
priority.** Content-hugging and compression-resistance only install their constraints on an axis where
`intrinsicContentSize` returns a real value. A view sized purely by its own internal constraints (a
`KeycapView`: an inner token stack pinned leading/trailing + a height constant) returns
`noIntrinsicMetric`, so `setContentHuggingPriority(.required, …)` **on that view** is a silent no-op:
there is nothing for the priority to attach to. Inside an `NSStackView` (default `.fill` distribution)
it is then the only elastic member and absorbs every point of slack: a one-glyph keycap stretched into
a wide pill, because the neighboring `NSTextField` ships with horizontal hugging 251, one above the
keycap's transitively-inherited 250, and wins the tie for who does *not* stretch. Override
`intrinsicContentSize` to report the width the view's own constraints already produce
(`tokenStack.fittingSize.width + insets`), and `invalidateIntrinsicContentSize()` when its content
changes; only then do hugging/compression priorities engage. Setting those priorities at the call site
is correct code aimed at nothing until the view itself reports an intrinsic size (ZEN-262).

**In an `NSStackView`, name the view that absorbs the slack. The solver's default is rarely what you
meant.** When a stack's main axis is larger than the sum of its content, `distribution` hands the extra
to the arranged views; the default `.fill` grows the **lowest** content-hugging view first. The slack is
often invisible in the code: a `.leading`- or `.trailing`-aligned *cross*-axis still sizes the stack to
its widest child, so every narrower row is stretched to that width and one view inside each has to take
up the difference. Keep it deterministic in two moves. Give anything that should hold its natural size
a real width (an `intrinsicContentSize`, per above, or an explicit constraint) so it is not a growth
candidate, and make the one thing that *should* flex (a trailing spacer, or a label with a truncating
`lineBreakMode`) the lowest-hugging so the slack lands there on purpose. Spacing follows the same "be
explicit" rule: uniform `spacing` sits between every pair, and `setCustomSpacing(_:after:)` overrides a
single gap, so reach for it rather than padding a view to fake a wider gap, since a padded view is one
more thing the distribution can stretch. The keycap-pill bug was the general failure in miniature: the
keycap was the only view with no real resistance, so it was the one that grew (ZEN-262).

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

**A drop shadow can't be made outside-only by reshaping `shadowPath`.** Core Animation *fills*
`shadowPath` and blurs the result, so the shadow covers the card's interior as well as haloing it.
That is free while the card is opaque and paints over it, and becomes a wash across the interior the
moment anything behind it turns translucent. The tempting fix, an even-odd path of an inflated
outer rect minus the card, does not work, and fails in a way that looks like a tuning problem
rather than a design one: a shadow decays outward *from* a filled silhouette, so a ring makes the
glow ramp **up** as it travels out instead of fading, and the inflation moves the outer edge with
it. The result is a large dense cloud, at any inflation. The silhouette has to stay the card, and
the cut has to happen at draw time: clip to everything outside the card (`ctx.clip(using: .evenOdd)`
over the bounds plus the card path), set the shadow, then fill the card path. The fill is clipped
away and only the outward half of its shadow survives, with the falloff unchanged. `OutsideShadowView`
is the shared implementation, used for the pane focus glow (ZEN-282) and the float's elevation
shadow (ZEN-287).

**`CGContext` blur and `CALayer.shadowRadius` are not the same scale**, so a layer shadow's radius
cannot be carried across when it becomes a drawn one. Measured by rendering both and sampling the
alpha profile out from the card edge: a context blur of **28** tracks a layer radius of **14** point
for point, at the same colour alpha. A literal 14 lands at roughly half the reach and reads as a
shadow that lost its lift. Measure rather than eyeball it: the two-line calibration is a `CALayer`
with a `shadowPath` rendered via `layer.render(in:)` (which does render the shadow, at the context
origin, ignoring the layer's frame) against the view's own `draw`, then compare the profiles.

**`layout()` cannot read a descendant's frame.** AppKit lays a tree out top-down, so when a view's
`layout()` runs, its own subviews have been positioned but anything deeper has not: it still holds
the frame from the *previous* pass. `PanelHostView` derived its padding-ring cutout from the
terminal's frame two levels down and got stale geometry on every fresh panel, self-correcting at
whatever later layout happened to come along (a resize, a tab switch), which is what made it look
like a rendering bug rather than a layout one. Read a descendant's frame at **draw** time, which
runs after the whole tree is laid out, and have `layout()` do nothing but `needsDisplay = true`
(ZEN-282). The same ordering trap applies to anything else deriving geometry from below itself.

**A translucent layer can't rely on libghostty's top-left content pinning.** `IOSurfaceLayer` sets
`contentsGravity = kCAGravityTopLeft` deliberately, so a frame is never stretched while a resize is
in flight. That works because the layer is opaque over the terminal background: wherever the
drawable is smaller than the layer, the background fills in. Drop the layer out of opaque for
`background-alpha` and that uncovered region becomes a see-through block with a hard edge at the
drawable's bounds, most visible between a surface's first layout and its final size, and on every
resize after. Set `contentsGravity = .resize` whenever the surface is translucent so the last frame
stretches until the next one lands (ZEN-282).

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

## Motion and transitions

**A transition that mounts two views has to order them, and being mounted says nothing about being
visible.** `pinCanvas` mounts every tab canvas at the very back of the container so a canvas can
never cover a float card dismissing above it (ZEN-141). Two canvases are mounted at once for the
length of a transition, so that also put the arriving one *under* the outgoing one, which is opaque
and exactly the same size. Everything ran: the fade was on the layer, the workspace's drawer slides
were animating, and none of it was on screen. It read as a hard cut the moment the outgoing canvas
was detached, which looks like an animation that was deleted rather than one that is playing
somewhere invisible. Order the pair explicitly, and assert the subview index: `superview` membership
is not paint order, and no other assertion catches this (ZEN-300).

**Reduce Motion makes a `Motion` primitive run its completion synchronously, so a completion is not
a "later".** That is the documented contract, and it is what lets callers sequence work the same way
on both paths. The trap is a caller whose remaining work is *outside* that completion:
`installController` calls `mount` and then `c.start()`, so handing the workspace recipe to `mount`'s
completion put it ahead of the start it is specified to follow the moment Reduce Motion collapsed
the slide. The failure is invisible in the obvious assertion, because the recipe's drawers open
either way and only the region left holding focus differs. A call that may or may not animate should
report which it did, and let the caller sequence the already-landed case itself (ZEN-300).

## Config read once, then frozen

A recurring bug shape: a config value read **once at construction** and baked into a constraint
constant or a stored property, so it never re-applies on `.configDidChange` and silently needs a
relaunch. Half-live behavior reads as "the setting is broken" and is invisible to any test that
only checks the value parsed.

Three shipped instances, all the same shape wearing different clothes. `SplitContainerView` took
`gutter: CGFloat = ChromeMetrics.panelGap` as a **default argument** and stored it, so `pane-gap`
moved the canvas/drawer seam while the gap *between* panes stayed frozen. `ToastPresenter` pinned
its stack at `init`, and the presenter is built on the first toast, so a later `window-gutter`
change left an already-used window's toasts at the old offset. And `CommandPaletteOverlay` stored
the `[PaletteCommand]` array handed to `init`, where each command bakes its shortcut *glyph* in at
catalog-build time: `reapplyTheme()` genuinely tore down and rebuilt every row, so it looked live,
but the rebuilt rows replayed the snapshotted glyph and an open palette kept the old chord after a
rebind. **A rebuild is not a re-read**: check what the rebuild reads *from*. Fixed by storing
`() -> [PaletteCommand]` and re-resolving.

**When one turns up, sweep the class rather than fixing the instance.** Grep every
`ChromeMetrics.*` / `GeneralConfig.current.*` read and classify each: rebuilt, index-updated,
retained-and-re-applied, computed live, or deliberately seed-only. Anything else is frozen. A
**default argument** is the easiest to miss, because the read isn't at the call site.

Two structural traps met while fixing these: a `lazy var` cannot be touched from a config observer
without constructing it (it was lazy for z-order), so hold it as an explicit optional and re-point
only when non-nil; and `animateSplitIn` detaches the constraints under test, so measure layout only
with reduce-motion pinned.

## Process-global state

**Release process-global macOS state on focus / app-active changes, not on surface teardown.** The
chrome detaches persistent surfaces with `removeFromSuperview` without calling `terminate()`/`deinit`,
so tying release to teardown leaks the global lock when a pane is merely hidden. Secure keyboard
entry (`EnableSecureEventInput`) left engaged after you Cmd-Tab away from a `sudo` prompt suppresses
keyboard input system-wide in other apps. Scope such state to the *focused* surface and tie it to
`NSApplication.didResignActive` / `didBecomeActive` (ZEN-72).

## Carbon and the main thread

**Every TIS call is main-thread-only in a GUI app, and violating it does not look like a crash.** Called from a background queue in a running app it takes the whole
process down: exit code 6, no crash report, nothing on stderr, the Dock icon simply goes. There is
no exception to catch and no stack to read, so it presents as "the app closed" with no evidence.

It is reachable from further away than you would expect. Parsing the general config assembles the
keymap, and `KeymapAssembler` asks `KeyboardLayout.canType` whether each bound chord can be typed
on the current layout, which is the TIS call. So **`ConfigLoader.loadGeneralConfig` is
main-thread-only**, and so is anything that reaches it, which includes every config reload.

**The compiler enforces this now, and two pieces are load-bearing (ZEN-31).** `@MainActor` on
`loadGeneralConfig` / `loadAppTheme` / `AppConfig.reload` is only half of it: in Swift 5 language
mode an isolation violation is a hard error in a synchronous function body but **a warning inside a
closure**, and a closure (`DispatchQueue.async { … }`) is exactly the shape that killed the app. The
other half is `.treatWarning("ActorIsolatedCall", as: .error)` on the ZenTerm target in
`Package.swift`, which is what makes both of those shapes fail the build. Delete that line and the
hole re-opens with everything still green.

**One shape stays invisible to the compiler, so it is guarded at runtime instead.** A closure formed
in a main-actor context and handed to `DispatchQueue.async(execute:)` as a `DispatchWorkItem` is
type-erased at construction: the compiler sees nothing crossing, and the whole isolated chain runs
off-main. That is not hypothetical, it is the debounce idiom the Settings sections already use. So
the two TIS call sites each call `MainActor.preconditionIsolated()` immediately before the Carbon
call: `KeyboardLayout.producibleGlyphs` in the chrome, and `TerminalKit.KeyboardLayout.id`, which
`GhosttyHostView.keyDown` uses to spot an input method claiming a key. That converts the untrappable
failure (exit 6, no crash report, empty stderr) into a crash report that names the line. The 6.2 tools-version exists to carry it, and every target
pins `.swiftLanguageMode(.v5)` so the bump doesn't turn into an unplanned Swift 6 migration.
(Manifest argument order is `dependencies` → `swiftSettings` → `linkerSettings`.)

**Isolation is also erased across a function value**, so a function *parameter* has to carry the
annotation too. A plain `canType: (Chord) -> Bool` parameter erases the isolation of whatever is
passed in, so annotating the leaf (`KeyboardLayout.canType`) builds clean and lets an off-main
assembly build clean straight past it. `KeymapAssembler.assemble` therefore declares
`canType: @MainActor (Chord) -> Bool` and is itself `@MainActor` (ZEN-31). Annotate the **entry
point** that must be main-thread, not just the leaf.

**A property *read* is a different diagnostic from a *call*, and it cannot be escalated at
all.** `treatWarning` only reaches grouped diagnostics. Calling a `@MainActor` method from a
closure is `[#ActorIsolatedCall]`, which is escalatable. *Reading* a `@MainActor` property
from one is `main actor-isolated ... can not be referenced from a Sendable closure`, which
carries **no group** (confirm with `swiftc -print-diagnostic-groups`), so it can never be made
fatal. For a main-thread-only *value*, annotate the function that must be main-thread, not the
value it returns.

**At a callback boundary, `MainActor.assumeIsolated` beats a hop.**
`NotificationCenter.addObserver(queue: .main)` blocks and main-runloop `Timer` blocks are typed
nonisolated but always land on main; wrapping asserts that, where a `DispatchQueue.main.async`
hop would move the work to a later runloop turn and change behavior. Top-level code in
`main.swift` needs the same wrap.

**The test target is a cascade of its own with a one-line fix.** An XCTest method is a
synchronous nonisolated function body, so it *hard-errors* with no `treatWarning` needed:
annotating the chrome cost ~180 errors across 22 test files. `.defaultIsolation(MainActor.self)`
in the test target's `swiftSettings` fixes all of them with no source churn, and it is honest:
XCTest runs these on the main thread and they drive AppKit in real windows.

**`GeneralConfig.current` and `Theme.current` are deliberately not lazy** for the same reason. A
lazy static runs its initializer wherever the first touch lands, so a `= ConfigLoader.load…()`
default puts a main-thread-only call at the mercy of whichever reader gets there first. Both hold
the built-in default until `AppConfig.loadAtLaunch()` resolves them in
`applicationDidFinishLaunching`, before any window builds. Anything that needs real config earlier
than that has to move the load, not read around it.

**`swift test` will not catch this.** TIS is available in the xctest process and answers happily
off the main thread, so an off-main parse passes every test while killing the real app. This cost a
day of bisecting on ZEN-17, through four green repro attempts, one of them using the real config
verbatim. Anything moved onto a background queue near config, keybinds, or the keyboard layout has
to be checked in `swift run ZenTerm`.

Two things about finding it, since the symptom hides itself. `LogFileSink` writes on its own queue,
so the lines that would have named the call were lost when the process died: the last line logged is
a lower bound on where it got to, not the location. Probes have to `fsync` per call to be trusted.
And because there is no crash report, an empty `~/Library/Logs/DiagnosticReports` is not evidence
that the app exited cleanly.

**If you want the config read off the main thread, the read is the only part that can move.** Split
the file read from the parse, keep the parse on main, and verify in the app. ZEN-17 built exactly
that and then dropped it: the measured win was about 2.5 ms against a 180 ms debounce, which did not
justify the async seam it needed. The constraint above is the part worth keeping.

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
into the machine on every `swift test` otherwise (ZEN-235).

**Tests must not read the real user config either.** `GeneralConfig.current` reads
`~/.config/zen-term/config`, so a suite that doesn't pin it asserts against whatever the developer
happens to run. Pin `GeneralConfig.setCurrentForTesting(.builtIn)` in `setUp` and restore in
`tearDown`; create any path fixture the test needs rather than naming a directory that "exists"
(`~/notes` passes locally and fails on CI).

The nasty part is that the damage lands in a *different* suite. `SurfaceFloatOverlay` started
reading `background-alpha` at construction while `FloatShadowTests` / `ReapplyThemeTests` pinned
nothing; a real config running `background-alpha = 0` made those suites mount a live
`NSVisualEffectView` into a displayed window and drop it, which surfaced as two unrelated *toast*
suites failing a dismiss assertion roughly 2 runs in 5, while CI stayed green (ZEN-287). **Widen the
search whenever a change makes a type newly read `GeneralConfig.current`**: grep every suite that
constructs it, not just the one you edited. Suspect this class immediately when a test passes
locally and fails on CI, or fails only on Drew's machine. When an intermittent failure appears in a
suite you did not touch, run it on the base branch a few times first to establish whether it is
pre-existing.

**When the suite hangs, `sample <pid>` names the spinning function in one shot.** It normally
finishes in about 5s, so minutes means hung, not slow. Two shell traps around that: swift test
processes are named `swift-test` with a hyphen, so `pkill -f "swift test"` matches nothing, and
concurrent `swift test` runs deadlock on the SwiftPM lock.
