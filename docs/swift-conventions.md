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
contentMinSize = NSSize(width: 480, height: 320)  // HostWindow.init
```

## Event routing and the responder chain

**Custom menu-action selectors are resolved by the responder chain, and the window delegate is
reached before the app delegate.** A menu item with a nil target sends its action via
`NSApp.targetForAction`, which walks: firstResponder up its chain, the window, the *window's
delegate*, the window controller, `NSApp`, then `NSApp`'s delegate. `WindowController` is the window
delegate, so it is found and invoked ahead of `AppDelegate`, and the search stops there. Any
conditional routing (e.g. "when a modal card is up, send copy/paste to the focused field instead of
the terminal") must live on the responder that is actually reached first. A copy of the same guard
in `AppDelegate` is dead code that never runs. The terminal surface controllers
(`PaneCanvasController`, `TabController`) are plain `NSObject`, never real responders in that chain,
so they are only ever reached through `WindowController`'s own manual dispatch.

**Never present a sheet inside `mouseDown`.** `NSOpenPanel` / `NSSavePanel` / `NSAlert`'s
`beginSheetModal(for:)` called synchronously within a `mouseDown` dispatch, before the matching
`mouseUp`, is silently dropped by AppKit: the sheet never attaches, nothing appears, no error.
Present from a control's action instead (an `NSButton`/`AppButton` fires on `mouseUp` via
`sendAction`), or defer to the next runloop turn. This is why the directory picker moved from a
click-on-the-empty-field affordance to an explicit Choose button.

**Some keys never reach `keyDown` at all, because AppKit's key-equivalent dispatch takes them
first.** Ctrl-Return goes to a default context-menu equivalent, Ctrl-/ is offered to the first view
in the *hierarchy* rather than to the first responder (and macOS beeps at it), and a command key
can be redirected into `doCommand(by:)` with no `keyDown` behind it. `GhosttyHostView` overrides
`performKeyEquivalent`, ported from ghostty's `SurfaceView`: it declines while unfocused, passes
Ctrl-Return through verbatim, rewrites Ctrl-/ to Ctrl-_, and declines every other command or
control key *once*, recording its timestamp so a menu item still wins. `doCommand`'s redispatch is
what sends that event back to be claimed on the second pass, and `keyDown` clears the timestamp
before `interpretKeyEvents` so the round trip cannot loop. Ghostty's `keyIsBinding` branch is
dropped here: `KeyInterceptor` resolves chords at its monitor, ahead of all of this. The event
identity is a timestamp because an `NSEvent` reference does not survive the round trip, and
AppKit's zero-stamped synthetic events are declined outright for the same reason.

**A consumed `keyDown` leaves its `keyUp` behind, so the surface pairs them itself.**
`KeyInterceptor` is a local `NSEvent` monitor that resolves a chord *before* the responder chain,
and it matches only `[.keyDown, .flagsChanged]`. Consuming a chord therefore consumes half a
keystroke: the `keyUp` still runs the chain into `GhosttyHostView`, which used to hand libghostty a
RELEASE for a PRESS it was never told about. Three other paths do the same, and all of them swallow
a press they cannot swallow the release of: the soft-newline chord, an input method taking the key,
and a composing key, which `key_encode.zig` drops without encoding. The fix is not to widen the
monitor's mask, which would cover only the first case. `GhosttyHostView` keeps a ledger of what it
actually sent (`reportedKeys`, `reportedModifierKeys`) and forwards a release only for a press it
made. Record at the point of sending, never earlier: every early return above it would owe a
release nothing sent.

**⌘ chords hide any `keyUp` bug, because macOS withholds `keyUp` entirely while Command is held.**
This one went unnoticed for the life of the app: every default chord is a ⌘ chord, so the unpaired
release never arrived to be seen. A user-bound `ctrl+h` is what exposed it. Never conclude a key
path is sound from ⌘ chords alone, and never conclude it from a *default* keymap either: a user
keybind moves its action, so which chords the chrome claims is a function of the user's config.

**Focus-loss cleanup has to match what libghostty actually retires, and only on the transition.**
`focusCallback` returns early when focus has not moved, so a repeated unfocused sync releases
nothing. A pane can be re-synced unfocused while it still holds first responder (scroll mode renders
it blurred), so a clear above `GhosttySurface.syncFocus`'s dedupe strands a modifier libghostty is
still holding. And it releases only its single `pressed_key` plus that key's modifiers, so clearing
every held ordinary key over-clears and swallows a release still owed.

**Synthesized `NSEvent`s must match what AppKit actually delivers.** Every arrow `keyDown` carries
`.function` *and* `.numericPad` on top of the modifier you care about, so comparing against
`.deviceIndependentFlagsMask` (which keeps those bits) never equals a bare modifier. Match against
the reservable set instead: `flags.intersection([.command, .shift, .option, .control])`. A
synthesized `modifierFlags: .option` event is a keystroke macOS never sends: it shipped a dead
⌥-arrow reorder past four green tests and a mutation check, because both only ever exercised the fake
event.

**A synthesized mouse event cannot carry a button number.** `NSEvent.mouseEvent` has no
`buttonNumber` parameter and every event it builds reports 0, whatever the type, so a test cannot
send a real middle click or side button. Split the coverage instead: drive an `.otherMouseDown`
through the window to prove the override runs, and test the button mapping as a pure function of
the number AppKit would have supplied. `NSEvent.ModifierFlags` has the opposite property: it
preserves any raw bits handed to `init(rawValue:)`, so the device-specific `NX_DEVICE*` flags that
say *which side* a modifier sits on do survive synthesis, and a `flagsChanged` built without them
skips every side check in silence.

**AppKit's synthesized tracking enter/exit are not symmetric across app activation.** When a
`.activeInActiveApp` tracking area stands down at app deactivation, AppKit synthesizes the
`mouseExited`; when the area reactivates with the pointer already inside it, no `mouseEntered`
arrives until the pointer physically moves. Proven against a live build with a raw mouse-report
probe: the exit's `(-1, -1)` reached libghostty, and a click after reactivation was
suppressed until the mouse moved. Occlusion boundaries within the active app *are* symmetric:
covering the pointer's spot with another window synthesizes the exit, uncovering it the enter. So
state pushed on exit that must be undone on re-entry needs its own
`didBecomeActiveNotification` restore; a `mouseEntered` override alone only covers real pointer
crossings and the occlusion pair.

**To prove an `NSView` override exists at all, let the responder chain answer.** `NSResponder`'s
default `flagsChanged` and `otherMouse*` implementations forward to `nextResponder`, so a recording
superview counts exactly the events the view under test declined to handle. That catches a missing
override, which is a whole class of bug no assertion about behavior can reach: with no override
there is no behavior to assert on.

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
`frameOfOutlineCell`/`frameOfCell` to seat them inside the pill.

**`NSTableView` shares the same `.automatic` inset trap.** Left at the default style, a plain
`NSTableView` reserves a source-list-style horizontal row inset, so its rows, and any full-row
selection or background, sit off the pane's leading and trailing edges by a fixed margin you never
asked for. The diff pane read as gapped from the tree divider on the left and the card edge on the
right until `table.style = .plain` removed it. Once it's `.plain`, add whatever margin you *do* want
explicitly (a leading/trailing constant on the table, or the row content's own insets) so the amount
is yours, not the framework's, and a full-row pill takes no extra inset of its own on top of that
margin, or it nests a second gap inside the first.

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
document's reported frame width.

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
.

**Anything driven from `setFrameSize` sees every frame the layout passes through, not the one it
lands on.** Auto Layout walks a view through intermediate frames while it solves, and a few of them
are nonsense: a pane briefly a handful of pixels wide, a zero-height strip mid-animation. Work
triggered from inside that override runs for all of them. The terminal pushed each intermediate
frame into libghostty, which rewrapped the whole scrollback for every one, and a rewrap into one or
two columns evicted history that no later width brought back: **dragging a window narrow and back
destroyed scrollback**. Ghostty's own `SurfaceView_AppKit` says the rule in a comment we had not
followed, that it is very important to use the size you are going for and *not* the view frame.
The fix is to queue the work to the end of the runloop turn (`GhosttyHostView.scheduleSizePush`),
so a pass lands as one push at the size it settled on. That is not the same as debouncing: a drag
delivers one turn per event, so live reflow is unchanged and only the garbage inside a single pass
is dropped. Any state guarding the work (here the `setSizeSyncSuspended` hold) has to be re-read
when the queued work runs, not only when it was queued.

**An `NSTextField` label sized to the exact glyph advances truncates to `…`.** A label insets its text
a couple of points inside its frame, so a column sized to `characters * digitWidth` is a hair too
narrow and clips even a single digit. Size a content-fit label to its string plus a few points of
padding (`DiffCellMetrics.numberColumnWidth`), or measure the actual string with the label's own
attributes and pad, never the raw advance sum.

**A non-truncating label holds its container, and the window, open.** A label defaults to a high
horizontal compression resistance and no truncation, so its intrinsic width becomes a hard floor for
everything it's pinned inside. A long value (a footer showing the full branch name) propagated up
through the card's proportional width constraint and *stopped the window from reaching its own
`contentMinSize`*. For any label that should yield when space is tight, set a truncating
`lineBreakMode` **and** lower its horizontal compression resistance
(`setContentCompressionResistancePriority(.defaultLow, for: .horizontal)`) fixes it; setting it on the
enclosing `NSStackView` is not enough; the child label resists on its own.

**Two optional constraints at the same priority do not have a stable winner.** The diff tree's
proportional width and its branch title's compression resistance were both priority 250. Either
truncating the title or widening the tree satisfied an equal amount of optional pressure, so a
key-window relayout could choose the other solution and make the tree jump wider. Give the intended
winner a strict ordering while keeping both below any window-sizing boundary: the tree proportion is
251, title compression is 250, and the window stay-put constraint is 500.

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
is correct code aimed at nothing until the view itself reports an intrinsic size.

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
keycap was the only view with no real resistance, so it was the one that grew.

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
highlighting existed.

**Asserting a label's frame width does not prove its text is drawn.** The bug above passed every test,
including window-based ones through the real table, because they measured `frame.width` against the
string's measured width and those matched. The frame was never wrong; the *drawing* was. For text that
must appear in full, assert the property that governs drawing (here the paragraph style's
`lineBreakMode`), not the geometry around it.

## Layers, shadows, and colors

**Static layer shadows go on `NSView.shadow`, not `layer.shadowOpacity`.** Setting
`layer.shadowOpacity` on a layer-backed view *before it joins a window* does not stick: inserting a
subtree (an overlay containing a card) makes AppKit re-realize the backing layers and re-sync
`NSView.shadow == nil` to `layer.shadowOpacity = 0` (radius/offset/color survive, so it looks
half-configured). Use `NSView.shadow = NSShadow(...)` for static shadows (survives the re-sync,
combines fine with an explicit `layer.shadowPath`). Direct `layer.shadow*` writes are only safe
*after* insertion, which is why animated focus glows driven post-mount work.

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
is the shared implementation, used for the pane focus glow and the float's elevation
shadow.

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
. The same ordering trap applies to anything else deriving geometry from below itself.

**A translucent layer can't rely on libghostty's top-left content pinning.** `IOSurfaceLayer` sets
`contentsGravity = kCAGravityTopLeft` deliberately, so a frame is never stretched while a resize is
in flight. That works because the layer is opaque over the terminal background: wherever the
drawable is smaller than the layer, the background fills in. Drop the layer out of opaque for
`background-alpha` and that uncovered region becomes a see-through block with a hard edge at the
drawable's bounds, most visible between a surface's first layout and its final size, and on every
resize after. Set `contentsGravity = .resize` whenever the surface is translucent so the last frame
stretches until the next one lands.

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
notification lands (ghostty-org/ghostty#2731).

**Never hardcode a color, and remember that system-derived colors count.** They do not look like
colors but they resolve against the view's `effectiveAppearance`, not `Theme.current`, so they wash
out on light themes: `NSTextField.placeholderString` (renders in the system `placeholderTextColor`),
`NSColor.secondaryLabelColor` / `.labelColor` / `.controlTextColor` / `.placeholderTextColor`,
`NSColor(white:)`. Use theme-derived values: for placeholders, a `placeholderAttributedString`
colored from a `ChromeTheme` role. See the Colors section in `CLAUDE.md`.

## Motion and transitions

**A transition that mounts two views has to order them, and being mounted says nothing about being
visible.** `pinCanvas` mounts every tab canvas at the very back of the container so a canvas can
never cover a float card dismissing above it. Two canvases are mounted at once for the
length of a transition, so that also put the arriving one *under* the outgoing one, which is opaque
and exactly the same size. Everything ran: the fade was on the layer, the workspace's drawer slides
were animating, and none of it was on screen. It read as a hard cut the moment the outgoing canvas
was detached, which looks like an animation that was deleted rather than one that is playing
somewhere invisible. Order the pair explicitly, and assert the subview index: `superview` membership
is not paint order, and no other assertion catches this.

**Reduce Motion makes a `Motion` primitive run its completion synchronously, so a completion is not
a "later".** That is the documented contract, and it is what lets callers sequence work the same way
on both paths. The trap is a caller whose remaining work is *outside* that completion:
`installController` calls `mount` and then `c.start()`, so handing the workspace recipe to `mount`'s
completion put it ahead of the start it is specified to follow the moment Reduce Motion collapsed
the slide. The failure is invisible in the obvious assertion, because the recipe's drawers open
either way and only the region left holding focus differs. A call that may or may not animate should
report which it did, and let the caller sequence the already-landed case itself.

## Config read once, then frozen

A recurring bug shape: a config value read **once at construction** and baked into a constraint
constant or a stored property, so it never re-applies on `.configDidChange` and silently needs a
relaunch. Half-live behavior reads as "the setting is broken" and is invisible to any test that
only checks the value parsed.

Three shipped instances, all the same shape wearing different clothes. `SplitContainerView` took
`gutter: CGFloat = ChromeMetrics.panelGap` as a **default argument** and stored it, so `pane-gap`
moved the canvas/drawer seam while the gap *between* panes stayed frozen. `ToastPresenter` pinned
its stack at `init`, and the presenter is built on the first toast, so a later `window-gutter`
change left an already-used window's toasts at the old offset; `toast-duration` would have landed
the same way, and rides the same `reapply` path for the same reason. And `CommandPaletteOverlay` stored
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
`NSApplication.didResignActive` / `didBecomeActive`.

**A `DispatchGroup` drain reports "done" when the work has not started yet.** `notify` fires the
moment the group is empty, and empty means *nothing is in flight*, which is indistinguishable from
*nothing has begun*. Quit freed every surface and then waited on the group, but the shells had not
exited yet, so nothing had entered it: the drain fired immediately and the process left before a
single signal went out. Wait on the **condition you actually care about** (the ledger of
recorded sessions emptying) and use the group only for work already entered. Where a gap between
"claim the work" and "enter the group" exists, hold the group across both, or a drain landing in
that window sees idle.

**Wait for the event, not for a duration you guessed.** The same sweep polled for orphaned sessions
inside a fixed 1.0s window, chosen against a measured 45ms. A session leader slower than that was
never swept at all, because nothing rescheduled a look. There is no correct number: a shell waiting
on a foreground child exits when that child does. These leaders are the app's own direct children,
so `DispatchSource.makeProcessSource(identifier:eventMask: .exit)` names the moment exactly.
Registering against a child that has already exited still fires, because an unreaped child stays in
the table as a zombie, so the race between snapshotting and arming is safe. Treat a fire as a prompt
to re-check rather than as proof, and a recycled pid costs one wasted look instead of a wrong kill.

## Carbon and the main thread

**Every TIS call is main-thread-only in a GUI app, and violating it does not look like a crash.** Called from a background queue in a running app it takes the whole
process down: exit code 6, no crash report, nothing on stderr, the Dock icon simply goes. There is
no exception to catch and no stack to read, so it presents as "the app closed" with no evidence.

It is reachable from further away than you would expect. Parsing the general config assembles the
keymap, and `KeymapAssembler` asks `KeyboardLayout.canType` whether each bound chord can be typed
on the current layout, which is the TIS call. So **`ConfigLoader.loadGeneralConfig` is
main-thread-only**, and so is anything that reaches it, which includes every config reload.

**The compiler enforces this now, and two pieces are load-bearing.** `@MainActor` on
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
call: `KeyboardLayout.glyphsByKeyCode` in the chrome, and `TerminalKit.KeyboardLayout.id`, which
`GhosttyHostView.keyDown` uses to spot an input method claiming a key. That converts the untrappable
failure (exit 6, no crash report, empty stderr) into a crash report that names the line. The 6.2 tools-version exists to carry it, and every target
pins `.swiftLanguageMode(.v5)` so the bump doesn't turn into an unplanned Swift 6 migration.
(Manifest argument order is `dependencies` → `swiftSettings` → `linkerSettings`.)

**Isolation is also erased across a function value**, so a function *parameter* has to carry the
annotation too. A plain `canType: (Chord) -> Bool` parameter erases the isolation of whatever is
passed in, so annotating the leaf (`KeyboardLayout.canType`) builds clean and lets an off-main
assembly build clean straight past it. `KeymapAssembler.assemble` therefore declares
`canType: @MainActor (Chord) -> Bool` and is itself `@MainActor`. Annotate the **entry
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
day of bisecting, through four green repro attempts, one of them using the real config
verbatim. Anything moved onto a background queue near config, keybinds, or the keyboard layout has
to be checked in `swift run ZenTerm`.

Two things about finding it, since the symptom hides itself. `LogFileSink` writes on its own queue,
so the lines that would have named the call were lost when the process died: the last line logged is
a lower bound on where it got to, not the location. Probes have to `fsync` per call to be trusted.
And because there is no crash report, an empty `~/Library/Logs/DiagnosticReports` is not evidence
that the app exited cleanly.

**If you want the config read off the main thread, the read is the only part that can move.** Split
the file read from the parse, keep the parse on main, and verify in the app. It was built exactly
that and then dropped it: the measured win was about 2.5 ms against a 180 ms debounce, which did not
justify the async seam it needed. The constraint above is the part worth keeping.

## Testing AppKit

**AppKit controls get window-based interaction tests, not state-only tests.** A test that only reads
the backing view-model passes while the control is dead: that is exactly how a fully broken dropdown
shipped past two reviews. Drive the real control in a real window. "Mounted + focused" is the same
trap one layer up: `superview` membership says nothing about paint order, so a view buried behind a
sibling passes every reasonable-looking assertion. For layered views (float cards, overlays,
toasts), assert the subview index relative to what it must cover.

**Synthetic mouse events are not hit-tested to a view in a headless / off-screen window.**
`window.sendEvent(mouseDown/Up)` will not route to a target view when the window is not real and key,
and making it real and key orders it on screen (flashing UI in the test run, and any presented panel
along with it). So a click cannot be routed through the scroll/clip view to a control in a unit test.
Drive the control's `mouseDown` / `mouseUp` handlers directly with real `NSEvent`s (that still
exercises the control's own logic, not its backing state); leave "a real click at that point reaches
the control through the view tree" to a runbook step.

**A synthesized `keyDown` reaches the real input system, and what it commits is not the event's
`characters`.** `interpretKeyEvents` translates from the keyCode and the active layout, so an event
built with `characters: ""` still commits a letter. Whether it commits at all turns on
`NSApp.currentEvent`: `insertText` returns early while that is nil. A test running alone gets nil, a
test in a full suite cannot count on it, and which earlier case sets it was never pinned down. So a
test that drives `GhosttyHostView.keyDown` and rests on the no-text branch (the one where a composing
key goes unrecorded) has to use a key the layout produces no text for. Escape is the one that needs
no modifiers; an arrow or a function key works too, and has to carry the bits above or it is a
keystroke macOS never sends. With a letter there, the branch taken was the machine's choice: the test
passed under `--filter`, failed 2 runs in 5 in a full suite, and failed on CI.

The `currentEvent` half of that generalizes past the key path. Anything reading it for live
modifiers is reading state an earlier case can leave behind: `PaletteOverlay`'s Return hook passes
it into `activate`, where `RepoPickerOverlay` reads `.shift` as replace-the-tab, so every Return in
`PaletteInteractionTests` goes through `sendReturn`, which pins the event first (with or without ⇧)
instead of assuming nil. Assume nil and the assertion belongs to the order the suite ran in.

The pin is one-way. AppKit exposes no way to clear `currentEvent`, and SwiftPM runs every target in
one process, so once a case dequeues an event, nothing after it in the run sees nil. Write the key
tests to hold on either branch rather than to nil, which is what the escape key buys above.

**Tests must not mutate real OS state.** They run on the developer's machine. Do not clobber
`NSPasteboard.general` (snapshot it in `setUp`, restore in `tearDown`), and do not present a real
`NSOpenPanel` (inject a present-panel seam so the test asserts the wiring without a sheet). Both leak
into the machine on every `swift test` otherwise. A feature that writes to the pasteboard
takes it as an injectable property (`ScrollModeController.yankPasteboard`,
`DiffViewerOverlay.yankPasteboard`) so a test can point it at a board of its own.

**`needsDisplay` cannot tell you a redraw was requested.** AppKit holds it *true* on a view that has
never drawn, and setting it false on one does not stick, so it reads as a pending repaint whether or
not anything asked for one, so a test asserting it passes with the bug reinstated. When "did this
ask to repaint" is the thing under test, route the request through a method that counts its calls
(`ScrollCursorView.redraw()`) and assert the count moved.

**A redraw keyed off an `Equatable` view-state is a trap for anything the state cannot see.**
Folding an overlay's fields into one value and repainting on `didSet` looks tidy and silently drops
every change that lives outside it: a font step moves the cell size without moving the view's frame
or the cursor, so the state compares equal and nothing repaints. Mark dirty unconditionally when the
geometry a view derives from is not part of what it stores.

**A window a test opens stays open for the whole run, so suites that mount views inherit
`WindowTestCase`, not `XCTestCase`.** XCTest tears down no AppKit state between cases. Nothing closed
its windows, so a full suite climbed monotonically to 69 live window-server surfaces, several
Metal-backed: every test ran under more load than the one before it, which is the load that
flakiness is sensitive to. `WindowTestCase` closes them.

**The sweep hangs off `tearDownWithError`, and the order is the reason.** XCTest runs
`tearDown()` *before* `tearDownWithError()`, and `addTeardownBlock` earlier than either: measured
order is test body, then teardown block, then `tearDown`, then `tearDownWithError`. Most suites here
clean up in `tearDownWithError`, so a sweep in `tearDown` closed their windows before their own
teardown body ran, and an explicit `controller?.windowWillClose(...)` became a no-op absorbed by
`WindowController`'s `didTearDown` guard. Everything still passed while the coverage those lines
exist for was gone. Sweeping from `tearDownWithError` after `super` puts it last, which holds only
because every subclass calls `super.tearDownWithError()` as its final statement.

Two details that decide whether the sweep works. **Close, do not order out:** a `WindowController`
drives its teardown from `windowWillClose`, so `close()` also invalidates the title poll and shuts
down every tab's shells, while `orderOut(_:)` leaves both running and the shells then outlive the
process as orphans (the failure mode, reproduced by the test suite itself). And
**`isReleasedWhenClosed` defaults to true for a window built in code**, so closing one the suite
still holds in a stored property frees it under ARC and the next access is a use-after-free: clear
the flag before closing.

That second one reads like a precaution and is not. Review flagged the cleared flag as a leak, since
a closed window then stays in `NSApp.windows` for the run; removing it segfaults the suite, signal
11, in `ConfigFanOutDifferentialTests`, because `WindowController` holds `let window: HostWindow`
and `close()` releases it while ARC still counts the owner. The residency is real and is the price:
it is bounded by the windows the suite builds, re-closing a closed window neither re-posts
`willClose` nor costs anything measurable, and the window-server surfaces this section is about are
still reclaimed. Do not re-litigate it without reproducing the crash first.

**`WindowTestCase` also owns the Reduce Motion override, so a suite pins it and restores nothing.**
`Motion.isReduceMotionEnabled` is a global closure, and window tests pin it to `{ true }` so
animations resolve instantly and a card is mounted by the time an assertion reads the tree. When
each suite put it back itself, 14 of them restored a hardcoded
`{ NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }`: they installed a fresh OS reader
rather than what they inherited, so a suite that pins Reduce Motion *off* to watch an animation run
passes or fails on file order. The base class captures the closure in a **property initializer**,
which runs when XCTest builds the case and therefore before any setup hook, so it does not depend on
which hook a subclass pins from. It restores *after* the sweep, because closing a window drives
`WindowController`'s teardown and that should still run under the setting the test chose. A suite
that is not a `WindowTestCase` carries its own copy (`MotionTests`). `MotionOverrideRestoreTests`
drives the restore directly, for the same reason `WindowSweepTests` drives the sweep: a teardown hook
that stops firing fails nothing. That test counts reads of the inherited closure rather than
comparing what the closure returns, because a value comparison passes with the bug reinstated on a
machine that has Reduce Motion switched on: the hardcoded restore returns `true` there too.

**Ordering a window in is also what runs its first layout pass, so anything that reads a view's
size has to force one.** `WindowController.mountAndStart()` deliberately does not present the
window, because a test wants the mounted tree and none of the presentation: with the
`makeKeyAndOrderFront` in it, a run peaked at 80 on-screen windows and took key from whatever was
being typed in, once per window test. Removing it broke 17 tests in five suites, all through the
same path: AppKit runs no automatic layout for a window that was never ordered in, so every host
view kept zero bounds and `PaneCanvasController.split` refused on `minSplitExtent` and beeped.
`mountAndStart` calls `layoutSubtreeIfNeeded()` itself. A suite that needs the window on screen or
key orders it in explicitly, and the ones testing key routing do.

Measure this with CoreGraphics, never the accessibility API. `xctest` runs `.prohibited`, so its
windows are on screen and in Mission Control while absent from the accessibility tree: System Events
reports `0` windows for the entire run. `CGWindowListCopyWindowInfo([.optionOnScreenOnly,
.excludeDesktopElements], kCGNullWindowID)` ignores activation policy and sees all of them. A null
result from System Events here is an artifact of the instrument, not evidence.

**Tests must not read the real user config either.** `GeneralConfig.current` reads
`~/.config/zen-term/config`, so a suite that doesn't pin it asserts against whatever the developer
happens to run. Pin `GeneralConfig.setCurrentForTesting(.builtIn)` in `setUp` and restore in
`tearDown`; create any path fixture the test needs rather than naming a directory that "exists"
(`~/notes` passes locally and fails on CI).

The nasty part is that the damage lands in a *different* suite. `SurfaceFloatOverlay` started
reading `background-alpha` at construction while `FloatShadowTests` / `ReapplyThemeTests` pinned
nothing; a real config running `background-alpha = 0` made those suites mount a live
`NSVisualEffectView` into a displayed window and drop it, which surfaced as two unrelated *toast*
suites failing a dismiss assertion roughly 2 runs in 5, while CI stayed green. **Widen the
search whenever a change makes a type newly read `GeneralConfig.current`**: grep every suite that
constructs it, not just the one you edited. Suspect this class immediately when a test passes
locally and fails on CI, or fails only on Drew's machine. When an intermittent failure appears in a
suite you did not touch, run it on the base branch a few times first to establish whether it is
pre-existing.

**When the suite hangs, `sample <pid>` names the spinning function in one shot.** It normally
finishes in about 5s, so minutes means hung, not slow. Two shell traps around that: swift test
processes are named `swift-test` with a hyphen, so `pkill -f "swift test"` matches nothing, and
concurrent `swift test` runs deadlock on the SwiftPM lock.

### A path is not a diff row identity

A repo-relative path can appear in more than one diff scope at once. For example,
the staged version and a later working-tree edit both produce rows for the same
path with different content. Diff selection and render deduplication must include
the scope and content represented by `FileDiff`, not only the path. That was exposed
this when switching between Staged and Unstaged kept the previously rendered diff.

### Event debounce does not provide load backpressure

A trailing filesystem debounce limits one burst, but separate settled bursts can arrive while
the work triggered by the first is still running. A watcher-driven subprocess path must also be
single-flight and retain one pending request. Rejecting stale completions only protects the UI;
it does not recover the CPU, disk work, or subprocesses already spent producing them. The watcher
must also follow any root the reader retargets to and stop on both card and window teardown
.

### An exhaustive switch does not cover the data table beside it

Adding a `ReservedChord` case fails to compile until four switches answer for it, which reads like
full coverage and is not. The Shortcuts card's row list is a hand-ordered array, so seven actions
shipped with a chord, a palette entry, a config token and no Settings row, and the whole suite
stayed green. An action missing from that array does not render wrong, it does not render, and a
test written against the array cannot notice an absence the array is the only record of.

The fix is a switch the table can be measured against: `isEditableInSettings` makes a new case
declare itself, and `SettingsKeybindGroupsTests` asserts the two agree in both directions. Any
hand-ordered list keyed off an enum needs the same pairing. Ordering and grouping are editorial and
belong in the array; membership is not, and belongs in a switch.

### A test's premise expires when the thing it measures moves

`BackendShadowTests` covered the whole assembler → layout → seam → C chain by rebinding nav away and
asserting the freed ⌘K came back as `clear_screen`. Naming that action and unbinding
libghostty's copy is the work succeeding, and the test went red for it.

The reflex is to delete a test whose premise is gone. Do not: the chain it covers is real and
nothing else covers it. Invert the assertion instead. It now asserts the freed set is **empty**
against a live backend, which is a regression guard on a currently-empty set, and the liveness
canary is what stops an empty result from meaning a dead probe. `BackendShadowSweepTests` is the
same shape, and both fail on the pin bump that would otherwise slip a bind back in unseen.
