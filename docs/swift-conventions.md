# Swift / AppKit conventions

AppKit and Swift traps past what a linter or the type checker catches. Read this before touching
window sizing, event routing, layers, config live-apply, or interaction tests. The testing rules
themselves live in `CLAUDE.md`; colors live in its Colors section. Add a trap when one bites: the
rule and the symptom.

## Windows and modals

**A resizable window must set an explicit `contentMinSize`.** Without one, AppKit derives the size
range from content constraints, and a modal card sized as a fraction of its container collapses that
minimum, clamping the window small while the modal is up. `HostWindow.init` pins the floor.

**AppKit exposes no window corner radius, and it changes between macOS versions.** Anything flush to
the window edge reads ragged against a constant. `CUIWindowFrameLayer` draws the rounding as frame art,
so no layer carries it; the private `_cornerRadius` does, on both `NSWindow` and its theme frame.
`WindowCorner.radius` reads it once from a probe window, with a fallback for when that stops working.

## Event routing and the responder chain

**A nil-target menu action reaches the window delegate before the app delegate.** The chain is first
responder, its ancestors, the window, the window's delegate (`WindowController`, a plain
`NSObject`), `NSApp`, then `NSApp`'s delegate. Conditional routing belongs on the first responder that
is actually reached; a copy of the guard in `AppDelegate` never runs. `PaneCanvasController` and
`TabController` are plain `NSObject`, reached only through `WindowController`'s own dispatch.

**Never present a sheet inside `mouseDown`.** A `beginSheetModal(for:)` before the matching `mouseUp`
is silently dropped. Present from a control's action (fires on `mouseUp`) or defer a runloop turn.

**Some keys never reach `keyDown`, because key-equivalent dispatch takes them first.** Ctrl-Return
goes to a context-menu equivalent, Ctrl-/ is offered to the first view in the hierarchy (and beeps),
and a command key can arrive only through `doCommand(by:)`. `GhosttyHostView.performKeyEquivalent`
handles these as ported from ghostty: Ctrl-Return passes through, Ctrl-/ becomes Ctrl-_, every other
⌘/⌃ key is declined once by timestamp so a menu item still wins, and `doCommand`'s redispatch claims
it on the second pass. Event identity is a timestamp because an `NSEvent` reference does not survive
the round trip.

**A consumed `keyDown` leaves its `keyUp` behind.** `KeyInterceptor` matches only
`[.keyDown, .flagsChanged]`, so a consumed chord's release still reaches `GhosttyHostView`. An input
method, a composing key, and the soft-newline chord swallow presses the same way. The surface keeps a
ledger of what it sent (`reportedKeys`, `reportedModifierKeys`) and forwards only paired releases.
Record at the point of sending, never earlier.

**⌘ chords hide `keyUp` bugs: macOS withholds `keyUp` while Command is held.** Never conclude a key
path is sound from ⌘ chords or from the default keymap. A user keybind moves its action, so what the
chrome claims depends on the user's config.

**Focus-loss cleanup must match what libghostty retires, and only on the transition.** Its focus
callback returns early when focus has not moved, and it releases only its single pressed key plus
modifiers. A clear above `GhosttySurface.syncFocus`'s dedupe, or a clear of every held key, strands or
over-clears releases. A surface already unfocused retires nothing on resign, so it sends its own
(`releaseHeldModifiers`).

**A tracking area is geometric: z-order and hit-testing do not gate it.** A view under an opaque
sibling still gets `mouseEntered`, so a hover feature suppressed by "something covers it" has to test
that state explicitly, and a covered `IconButton` still pops its tooltip. Hiding it is the only way to
silence it (`SidebarEdgeReveal`, `HoverSuppressing`).

**`SidebarView.setHoverCovered` clamps at zero going down, not going up.** A stray decrement is
harmless, a stray increment suppresses sidebar hover for the rest of the session with nothing to clear
it. Both call sites are balanced today, and a third has to be.

**AppKit drops `mouseEntered` when the pointer arrives inside the window's own resize band.** A view
tracking the window edge therefore never arms for a pointer that came in from outside the window, which
is exactly how a person reaches an edge. Arm on `mouseMoved` as well as on enter.

**Synthesized `NSEvent`s must match what AppKit delivers.** Every arrow `keyDown` carries `.function`
and `.numericPad`, so compare against `flags.intersection([.command, .shift, .option, .control])`,
never `.deviceIndependentFlagsMask`. A synthesized `modifierFlags: .option` arrow is a keystroke macOS
never sends, and tests built on it pass while the feature is dead.

**Keypad Enter is not CR and not a bare key.** It carries `.numericPad` and `.function` and types
ETX. Match keyCode 76 beside Return's 36, as `KeyboardFocus` and `SearchController` do.

**A synthesized mouse event cannot carry a button number.** `NSEvent.mouseEvent` always reports 0.
Drive an `.otherMouseDown` through the window to prove the override runs, and test the button mapping
as a pure function. `ModifierFlags(rawValue:)` does keep raw bits, so a synthesized `flagsChanged`
without the device-specific side flags skips every side check silently.

**Tracking enter/exit is not symmetric across app activation.** A `.activeInActiveApp` area
synthesizes `mouseExited` at deactivation but no `mouseEntered` at reactivation until the pointer
moves. State pushed on exit needs its own `didBecomeActiveNotification` restore.

**A tracking area is geometric and ignores whatever is painted over it.** A sibling view covering a
pane generates no `mouseExited`, so the view underneath keeps taking `mouseMoved` and keeps reporting
while the person points at something else. Occlusion is a hit test, not an event: gate on
`window?.contentView?.hitTest(_:) === self`, the routing `mouseDown` already gets. A drag has to be
exempt, since AppKit sends it to the view its press landed on wherever the pointer travels, but the
exemption is per-view ownership paired with live button state, never `NSEvent.pressedMouseButtons`
alone. Tracking delivers `mouseEntered` while a button is down, so a drag inside one view unlocks a
global exemption for every covered view in the window, and ownership without the button state
survives a release the view never saw.

**A cursor rect is not blind the same way.** A sibling's rect does win over the view beneath it, so a
view that covers another only has to claim its own, as `BackdropView` does. Nothing has to tell it a
cover went up. The seven `resetCursorRects` overrides in the chrome are all a child over its own
parent, so they do not answer this on their own.

**To prove an `NSView` override exists, let the responder chain answer.** Default `flagsChanged` and
`otherMouse*` forward to `nextResponder`, so a recording superview counts exactly the events the view
failed to handle. That catches a missing override, which no behavior assertion can.

## Scroll views

**`NSScrollView.contentInsets` is scrollable range, not padding.** A nonzero left/right inset makes
the clip pan sideways by that amount even when the document exactly fits. Use insets only on an axis
meant to scroll; get edge padding from the row content's own insets.

## Auto Layout, resize, and text sizing

**A width-responsive relayout keys off a frame-change notification, not a descendant's `bounds` in
`layout()`.** Descendants get their new frame after the ancestor's `layout()` returns, so the read is
one resize stale. Tests miss it because `layoutSubtreeIfNeeded()` flushes the whole subtree. Use
`postsFrameChangedNotifications` and `NSView.frameDidChangeNotification` on the view itself.

**`layout()` cannot read a descendant's frame at all.** Anything deeper than direct subviews still
holds the previous pass's frame. Read it at draw time and have `layout()` only set
`needsDisplay = true`, as `PanelHostView`'s padding ring does.

**An attributed value carries its own line behavior.** Once a label shows an attributed string, its
`lineBreakMode`, `alignment` and `font` stop applying, and the default paragraph style wraps: a
truncating label starts wrapping, or a one-line label silently drops words. Put a paragraph style and
font on every run and set `maximumNumberOfLines = 1` as a backstop. Assert the paragraph style, not
the frame width: the frame can be right while the drawing is wrong.

**Anything driven from `setFrameSize` sees every intermediate frame the solver passes through.**
Pushing those into libghostty rewrapped scrollback into one or two columns and destroyed history.
`GhosttyHostView.scheduleSizePush` queues the push to the end of the runloop turn, re-reads guards
(`setSizeSyncSuspended`) when it runs, and skips sizes under 1px.

**A label sized to its exact glyph advances truncates to `…`.** Labels inset their text, so pad a
content-fit width or measure with the label's own attributes and pad.

**Measure a wrapping label's text width from its alignment rect.** A wrapping `NSTextField` is about
2pt wider per side than its usable text width (`UpdateCardTests` reads `alignmentRect(forFrame:)`).
An `NSTextView` adds 5pt `lineFragmentPadding` per end; `TextAreaBox` sets it to 0.

**A non-truncating label holds its container, and the window, open.** High compression resistance
makes its intrinsic width a floor that can stop the window reaching `contentMinSize`. Give it a
truncating `lineBreakMode` and lower horizontal compression resistance on the label itself; setting it
on the enclosing stack is not enough.

**Two optional constraints at the same priority have no stable winner.** A relayout can pick either
solution and the layout jumps. Order them strictly (for example 251 over 250), both below the window
sizing constraints.

**A view with no `intrinsicContentSize` cannot resist stretching.** Hugging and compression priorities
attach only on an axis with an intrinsic value, so on a `noIntrinsicMetric` view they are no-ops and a
`.fill` stack stretches it (`KeycapView` became a wide pill). Report the width its constraints produce
and invalidate when content changes.

**In an `NSStackView`, name the view that absorbs slack.** `.fill` grows the lowest-hugging view, and
a leading/trailing cross-axis stretches every row to the widest child. Give fixed-size views a real
width, make the one flexible view the lowest-hugging, and use `setCustomSpacing(_:after:)` rather than
padding a view.

## Layers and shadows

**Static shadows go on `NSView.shadow`, not `layer.shadowOpacity`.** Inserting a subtree re-realizes
backing layers and resyncs `layer.shadowOpacity` from `NSView.shadow == nil`, so a pre-mount layer
shadow disappears. Direct `layer.shadow*` writes are safe only after insertion.

**A drop shadow cannot be made outside-only by reshaping `shadowPath`.** Core Animation fills the
path, so a ring path ramps the glow up outward. Clip to outside the card at draw time, set the shadow,
fill the card path. `OutsideShadowView` is the shared implementation.

**`CGContext` blur and `CALayer.shadowRadius` use different scales.** A context blur of 28 tracks a
layer radius of 14. Measure alpha profiles when converting one to the other.

**A translucent terminal layer cannot rely on top-left content gravity.** libghostty pins its drawable
top-left, which is invisible only while the layer is opaque. Below `background-alpha` 1 the uncovered
region shows as a hard-edged see-through block during resize. `GhosttySurface` switches
`contentsGravity` to `.resize` when translucent.

**A layer-hosting view owns its own `contentsScale`.** AppKit syncs scale only for layer-backed views,
and `GhosttyHostView` is layer-hosting. Set it in `viewDidChangeBackingProperties` inside a
`CATransaction` with actions disabled, and also observe `NSWindow.didChangeScreenNotification`,
re-running on the next turn because `backingScaleFactor` is not updated when it lands.

## Motion and transitions

**A transition that mounts two views has to order them.** `pinCanvas` mounts canvases at the back, so
the arriving canvas landed under the opaque outgoing one and the animation ran invisibly. Order the
pair explicitly and assert the subview index.

**Under Reduce Motion a `Motion` completion runs synchronously.** A caller whose remaining work sits
after the call (`installController` calls `mount` then `c.start()`) sees completion work run first.
A call that may or may not animate should report which, and let the caller sequence it.

## Config read once, then frozen

**A config value read at construction and stored never re-applies on `.configDidChange`.** The
setting looks broken until relaunch, and parse tests cannot see it. Watch for a default argument
(`gutter: CGFloat = ChromeMetrics.panelGap`), a presenter pinned at `init`, and a rebuild that replays
a snapshot: **a rebuild is not a re-read**, so store a closure and re-resolve.

**When one turns up, sweep the class.** Classify every `ChromeMetrics.*` / `GeneralConfig.current.*`
read as rebuilt, index-updated, re-applied, computed live, or deliberately seed-only. Anything else is
frozen.

**A `lazy var` cannot be touched from a config observer without constructing it.** Hold it as an
explicit optional and re-point only when non-nil.

## Process-global state

**Release process-global macOS state on focus and app-active changes, not surface teardown.** Hidden
surfaces are detached without `terminate()`, so secure keyboard entry tied to teardown stays engaged
and blocks input system-wide. Scope it to the focused surface and `didResignActive`/`didBecomeActive`.

**A `DispatchGroup` drain reports done before work has started.** Empty means nothing in flight, not
nothing pending. Wait on the condition you care about (the session ledger emptying), and hold the
group across any claim-then-enter gap.

**Wait for the event, not a guessed duration.** Session leaders are the app's direct children, so
`DispatchSource.makeProcessSource(identifier:eventMask: .exit)` names the moment. Arming against an
exited, unreaped child still fires. Treat a fire as a prompt to re-check.

## Carbon and the main thread

**Every TIS call is main-thread-only, and violating it exits with code 6, no crash report, no stderr.**
It is reachable from config: parsing the general config assembles the keymap, which asks
`KeyboardLayout.canType`. So `ConfigLoader.loadGeneralConfig`, and every reload, is main-thread-only.
`swift test` does not catch it, because TIS answers off-main in xctest. Check such changes in the
running app, and do not trust the last log line or an empty `DiagnosticReports` as evidence.

**The compiler enforces most of it, and two pieces are load-bearing.** `@MainActor` on
`loadGeneralConfig` / `loadAppTheme` / `AppConfig.reload`, and
`.treatWarning("ActorIsolatedCall", as: .error)` on every target, since in Swift 5 mode a
violation inside a closure is otherwise only a warning. Every target pins `.swiftLanguageMode(.v5)`.

**A `DispatchWorkItem` erases isolation, so the TIS sites guard at runtime.**
`KeyboardLayout.glyphsByKeyCode` and `TerminalKit.KeyboardLayout.id` call
`MainActor.preconditionIsolated()` before the Carbon call, turning a silent exit into a crash report.

**Isolation is erased across a function value.** Annotate the parameter
(`canType: @MainActor (Chord) -> Bool`) and the entry point, not only the leaf.

**A property read cannot be escalated to an error.** Reading a `@MainActor` property from a closure is
an ungrouped diagnostic that `treatWarning` cannot reach. Annotate the function that must be on main.

**At a callback boundary, `MainActor.assumeIsolated` beats a hop.** `addObserver(queue: .main)` blocks
and main-runloop timers always land on main; a `DispatchQueue.main.async` hop changes timing.

**The test target uses `.defaultIsolation(MainActor.self)`.** XCTest methods are nonisolated and run
on main, so this is accurate and avoids per-test annotation.

**`GeneralConfig.current` and `Theme.current` are not lazy.** A lazy static runs its initializer on
whichever thread touches it first. Both hold the built-in default until `AppConfig.loadAtLaunch()`.

**`UCKeyTranslate` takes the old Carbon modifier byte**, `(shiftKey >> 8) & 0xFF`, not
`NSEvent.ModifierFlags`. It returns control characters for arrows and Return;
`KeyboardLayout.glyphsByKeyCode` drops anything below 0x20 and 0x7F.

## Testing AppKit

The rules are in `CLAUDE.md`. These are the AppKit mechanics behind them.

**Mounted is not visible.** `superview` membership says nothing about paint order. For layered views
(floats, overlays, toasts), assert the subview index relative to what they must cover.

**Synthetic mouse events are not hit-tested in an off-screen window.** Drive the control's
`mouseDown` / `mouseUp` with real `NSEvent`s and leave click routing to the runbook.

**A render tears down a tooltip that has not appeared yet.** `SidebarView.refreshRowHover` suppresses
and then calls `row.refreshHover()`, which reads `pointerIsInside`; that is false whenever the window
is not key, and a test window is not key. So the first render after a synthesized `mouseEntered`
clears `isHovered`, hides the tooltip, and cancels `TooltipPresenter`'s 0.45s work item. It follows
hover order, not row kind, and a workspace open renders several times while it settles. Hover once the
window is quiet, or assert the row's own hover state rather than a presented tooltip.

**A synthesized `keyDown` commits text from the keyCode and layout, not `characters`, and only when
`NSApp.currentEvent` is set.** `currentEvent` cannot be cleared and leaks between cases, so a key test
must hold on either branch: use a key that types nothing (Escape, or an arrow with its real flags).
Code reading `currentEvent` for modifiers needs the event pinned first (`sendReturn` in
`PaletteInteractionTests`).

**A run-loop wait also lands work dispatched from the block it waited on.** Assert pre-async state
before anything turns the run loop, usually by building the view without mounting it.

**`RunLoop.run(mode:before:)` returns at once when nothing is attached.** Loop to a deadline, like
`waitUntil`.

**Drain on the queue the observer runs on.** A `queue: .main` observer is an `OperationQueue.main`
operation; enqueue the fulfill there.

**A weak reference to an AppKit view clears when the autorelease pool drains.** Wrap open and close in
`autoreleasepool` when testing for a leak.

**`kill(pid, 0)` succeeds on a zombie.** Where a zombie could answer, assert on elapsed time.

**Tests must not mutate or read real OS and user state.** Snapshot and restore `NSPasteboard.general`,
inject pasteboards (`ScrollModeController.yankPasteboard`) and panel presenters, pin
`GeneralConfig.setCurrentForTesting(.builtIn)`, and create path fixtures. An unpinned config read
fails in a different suite, often only on one machine. When a change makes a type newly read
`GeneralConfig.current`, grep every suite that constructs it. Check an intermittent failure against
the base branch before blaming the change.

**`needsDisplay` cannot tell you a redraw was requested.** It reads true on a never-drawn view. Route
the request through a counting method (`ScrollCursorView.redraw()`) and assert the count.

**A hidden view drops a redisplay request.** Unhide first, then mark: `stripsMoved()` re-reads the
background (unhiding the ring) before marking it.

**A redraw keyed off an `Equatable` view-state misses anything the state cannot see.** A font step
changes cell size without changing the state. Mark dirty unconditionally when derived geometry is not
stored.

**Suites that mount views inherit `WindowTestCase`.** XCTest tears down no AppKit state, so windows
accumulate across the run. Its sweep hangs off `tearDownWithError` after `super`, because XCTest runs
`tearDown` before `tearDownWithError` and most suites clean up in the latter; every subclass calls
`super.tearDownWithError()` last. It closes rather than orders out, because `windowWillClose` drives
teardown and orphaned shells otherwise outlive the process. It clears `isReleasedWhenClosed` before
closing: removing that segfaults the suite, since `WindowController` holds its window strongly.

**`WindowTestCase` also owns the Reduce Motion override.** It captures `Motion.isReduceMotionEnabled`
in a property initializer and restores it after the sweep, so suites pin and restore nothing.
`MotionOverrideRestoreTests` and `WindowSweepTests` drive the hooks directly, because a hook that stops
firing fails nothing.

**`mountAndStart()` does not order the window in, so it forces layout itself.** AppKit runs no
automatic layout for a window never ordered in; views keep zero bounds and `split` refuses on
`minSplitExtent`. Suites testing key routing order the window in explicitly. To count leaked windows by hand, use
`CGWindowListCopyWindowInfo`, not the accessibility API, which cannot see xctest's windows.

**When the suite hangs, `sample <pid>` names the spinning function.** The processes are named
`swift-test`, and concurrent `swift test` runs deadlock on the SwiftPM lock.

**An exhaustive switch does not cover the data table beside it.** A hand-ordered list keyed off an enum
can silently omit a case. Pair it with a switch the table is measured against (`isEditableInSettings`
and `SettingsKeybindGroupsTests`): ordering belongs in the array, membership in the switch.

**When a test's premise expires, invert it rather than deleting it.** `BackendShadowTests` and
`BackendShadowSweepTests` assert an empty freed set against a live backend, with a liveness canary so
empty cannot mean a dead probe.

## Exercising agents in a running build

**libghostty sends no desktop notification for a pane that is focused in the frontmost window.**
Typing `printf '\033]777;notify;claude;needs you\a'` into the pane you are watching produces nothing:
no agent row, no toast, no attention anywhere. It reads as the feature being dead. Arm it and leave
before it fires, `(sleep 20; printf '\033]777;notify;claude;needs you\a') &`, with a delay long enough
to survive the rest of the setup.

**Entering a window answers whatever pane is focused there.** `windowDidBecomeKey` runs
`answerFocusedAgent`, so returning to arm a second agent clears the first. A setup with more than one
waiting agent is armed in a single visit, and the window left alone until every timer has fired.

**A one-shot OSC 9;4 report does not leave an agent working.** `trackAgentExits` polls `isBusy` and
drops the row on the next poll. Keep the shell busy for as long as the row is needed:
`printf '\033]9;4;3;0\a'; sleep 120`.
