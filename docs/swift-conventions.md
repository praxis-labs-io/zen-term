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
rebind. **A rebuild is not a re-read** — check what the rebuild reads *from*. Fixed by storing
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
the two TIS call sites — `KeyboardLayout.producibleGlyphs` in the chrome and
`TerminalKit.KeyboardLayout.id`, which `GhosttyHostView.keyDown` uses to spot an input method
claiming a key — each call `MainActor.preconditionIsolated()` immediately before the Carbon call. It converts the untrappable failure (exit 6, no crash report, empty stderr) into a crash
report that names the line. The 6.2 tools-version exists to carry it, and every target
pins `.swiftLanguageMode(.v5)` so the bump doesn't turn into an unplanned Swift 6 migration.
(Manifest argument order is `dependencies` → `swiftSettings` → `linkerSettings`.)

**Isolation is also erased across a function value.** `KeymapAssembler.assemble(...,
canType: (Chord) -> Bool = KeyboardLayout.canType)` takes the isolated method as a plain
`(Chord) -> Bool`, so annotating the leaf builds clean and lets the bug build clean too.
Annotate the **entry point** that must be main-thread, not the leaf.

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
in the test target's `swiftSettings` fixes all of them with no source churn, and it is honest —
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
search whenever a change makes a type newly read `GeneralConfig.current`** — grep every suite that
constructs it, not just the one you edited. Suspect this class immediately when a test passes
locally and fails on CI, or fails only on Drew's machine. When an intermittent failure appears in a
suite you did not touch, run it on the base branch a few times first to establish whether it is
pre-existing.

**When the suite hangs, `sample <pid>` names the spinning function in one shot.** It normally
finishes in about 5s, so minutes means hung, not slow. Two shell traps around that: swift test
processes are named `swift-test` with a hyphen, so `pkill -f "swift test"` matches nothing, and
concurrent `swift test` runs deadlock on the SwiftPM lock.
