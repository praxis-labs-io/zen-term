# Architecture

What ZenTerm is, as it exists today. If a change makes this wrong, the change
fixes this file.

ZenTerm is the chrome around a terminal. Ghostty renders text and runs shells;
everything else here is ours.

## The seam (load-bearing)

`TerminalSurface` (`Sources/TerminalKit/TerminalSurface.swift`) is the whole
contract, and it is deliberately small. A surface is anything that can *be* a terminal inside our
chrome: it vends an `NSView`, a title, a cwd, a busy flag, and the background its
program last reported, and it takes
`start`, `focus`, `terminate`, `paste`, `copySelection`, `applyAppearance`,
`setFontSize`.

**`setFontSize` is separate from `applyAppearance` on purpose.** Appearance travels
as a whole theme through the app-global config, which on a file-configured backend
costs a synchronous write/read/parse per distinct value: fine for a theme swap,
not for a size the user is holding a key to change (ZEN-224). It takes an absolute
size, never a delta, so the chrome stays the single owner of the number: a stepping
API would leave the running size inside each surface where the chrome can't read it
back, and surfaces would drift apart at whatever bounds the backend enforces.

Four types travel with it: `TerminalSurfaceConfig` (spawn params),
`TerminalSurfaceDelegate` (ten events out, all defaulted to no-ops),
`TerminalTheme`, and `TerminalBehavior`.

**The rule:** if only one backend can do a thing, it stays below the seam. The
protocol grows only to hold what the chrome needs from *any* terminal.

Two contract details that are not decoration:

- **`setFocused` is not `focus()`.** The chrome drives cursor focus from its own
  single-focus model rather than the AppKit responder chain, which doesn't
  propagate reliably while many pane views are reparented in one pass (rapid
  splits).
- **`surfaceDidFailToStart` must be delivered asynchronously**, never
  synchronously inside `start`, so a consumer dispatching on surface identity has
  finished wiring the surface into its state first. `GhosttySurface.swift:92`
  honors this with a `DispatchQueue.main.async`.

## Targets

```
GhosttyKit (binaryTarget: Frameworks/GhosttyKit.xcframework)
     ↑
TerminalKit          the ONLY target that may import GhosttyKit
     ↑
  PaneKit            seam types only, never the backend
     ↑
  ZenTerm            the chrome
     ↑
  TabKit             pure: no AppKit, no backend

  AppLog             pure leaf (Foundation + os); TerminalKit and ZenTerm
                     depend on it for diagnostic logging (ZEN-11)
```

**Nothing lints this. The package graph does.** `ZenTerm` has no dependency on
`GhosttyKit`, so `import GhosttyKit` in the chrome is a compile error.
`import GhosttyKit` appears in exactly five files, all under `Sources/TerminalKit/`.

Two more guards: `TerminalSurfaceFactory.make()` is the one place the chrome asks
for a terminal, and `Tests/TerminalKitTests/SeamTests.swift` asserts the factory
returns a `GhosttySurface` while proving the protocol is implementable with zero
backend (`SpySurface`).

`PaneKit` and `TabKit` import no AppKit. TabKit imports nothing at all.

`AppLog` is a zero-dependency leaf (Foundation + `os`) that both `TerminalKit`
and `ZenTerm` use for logging, so it sits below the seam and imports neither the
backend nor the chrome. `Log` tees every line to `os.Logger` (subsystem
`com.drucial.ZenTerm`, keyed by category) and to a rotating file at
`~/Library/Logs/ZenTerm/zen-term.log` (~5 MB × 2), written off the main thread.
Warnings, errors, and a thin key-event trail (surface start/stop, split, close
pane, drawer toggle, zoom, tab open/close/switch) are always on; `debug` lines
tee to the file only under the verbose gate (config `debug = true` or
`ZENTERM_LOG_VERBOSE=1`).

Help ▸ Export Diagnostics writes a `.zip` of those log files plus a `metadata.txt`
(app version, macOS version, arch) for a bug report. `DiagnosticsBundleBuilder`
(in `ZenTerm`) assembles it from the sink's `fileURLs` and a `SystemReport`, and
carries only what it's handed, so the shell environment and the config file never
leak in; the zip is produced with `NSFileCoordinator`'s `.forUploading`, no
third-party archiver. `SystemReport` is the shared metadata source: Help ▸ Report
an Issue (`ReportIssueOverlay`) opens a composer whose `IssueReport`/`SupportLinks`
build a prefilled GitHub new-issue URL on the same `SystemReport` block, so the
exported diagnostics header and a filed issue can't disagree. The app has no
backend, so it opens the browser to file; a dragged-in diagnostics zip attaches
the logs. The composer is reached three ways: the Help menu, a quiet link below
the version in Settings, and the command palette (a `report_issue` action that
ships unbound, like `check_for_updates`).

**GhosttyKit and its resources are gitignored and built per machine**
(`bin/build-ghosttykit`). A fresh worktree or clone needs
`Frameworks/GhosttyKit.xcframework` and
`Sources/TerminalKit/Resources/ghostty-resources` symlinked in from the main
checkout, or the build fails with "local binary target 'GhosttyKit' … does not
contain a binary artifact", then "'module' is inaccessible" (the missing Resources
dir suppresses TerminalKit's `Bundle.module` accessor).

**Those symlinks show up as untracked, unlike in the main checkout.** Both
`.gitignore` patterns end in a trailing slash, which matches a directory, and a
symlink is not a directory to git. So `git add -A` in a worktree commits them. Use
`git add -u` and check `git diff --cached --name-only` before committing.

**Never call `Bundle.module` in shippable code.** For a statically-linked
executable target it resolves via the SwiftPM-generated "executable" accessor,
which checks only `Bundle.main.bundleURL/<name>.bundle` (the `.app` *root*) and a
build-machine-absolute `.build/.../release/<name>.bundle` path, then `fatalError`s.
In a real `.app` the resource bundles must live in `Contents/Resources`, which that
accessor never checks, so the app runs on the build machine (its hardcoded `.build`
path exists) and SIGTRAPs on first access for every downloader. This shipped in
v0.1.1. Use `Bundle.zenResourceBundle(named:fallback:)`
(`Sources/TerminalKit/Bundle+ZenResource.swift`), which checks
`Bundle.main.resourceURL`/`bundleURL` first and defers to `.module` only via
`@autoclosure` for `swift test`. The general heuristic: "works when I build it,
crashes for downloaders" means a dev-machine-absolute path baked into the binary is
masking a resolution failure.

## The backend

`GhosttySurface` + `GhosttyApp` + `GhosttyHostView` + `GhosttyHostViewIME` +
`GhosttyConfigWriter`, all in `TerminalKit`.

- **libghostty config is app-global.** One `ghostty_app_t` per process.
  `applyAppearance` on any surface calls `GhosttyApp.shared.updateConfig`, deduped
  by generated config text, so N surfaces cause one real swap. A consequence:
  **there is no per-surface theming.** Every pane shares one theme.
- **Font size is the exception to that, and it bites.** `setFontSize` goes through
  `ghostty_surface_binding_action("set_font_size:…")`, which performs the action
  inline with no config round-trip. libghostty then marks the surface
  `font_size_adjusted` and **stops applying config reloads to its font**, on the
  reasoning that the user asked for a specific size. So once a surface has been
  stepped, the theme's `fontSize` no longer reaches it: the chrome re-pushes
  `SessionFontSize.points` after every `applyAppearance`, or a theme edit leaves
  panes at two different sizes.
- **One surface can still run its own config.** `updateSurfaceConfig` pushes a
  config to a single surface without touching the app-global one, which is how the
  cursor shader stands down on an unfocused pane (ZEN-237). Theming stays global:
  the per-surface shape is rebuilt from the theme that just landed, so a stood-down
  surface follows an appearance change instead of holding the old one (ZEN-271).
- **libghostty accepts config only from files.** `GhosttyConfigWriter` writes to
  `$TMPDIR/zenterm-ghostty-config-<pid>`. It deliberately does *not* call
  `ghostty_config_load_default_files`, so a user's `~/.config/ghostty` cannot skew
  ZenTerm's appearance. Because that means a synchronous write, read and parse on
  the main thread, the per-surface configs are cached by their generated text and
  cleared when the app-global config moves (ZEN-90, ZEN-271).
- **A per-surface config push must carry that surface's font size.** `Surface.updateConfig`
  resets the size of any surface libghostty has not marked `font_size_adjusted` to
  whatever the pushed config says, so a push built from the theme alone silently
  drops a pane's stepped size. `updateSurfaceConfig` takes a `fontSize` for this;
  the app-global config leaves it nil, where the theme's size is correct by
  definition (ZEN-224).
- **The generated config's `theme` line is not a theme.** It names two files
  (`$TMPDIR/zenterm-ghostty-scheme-<pid>-{light,dark}`) that ZenTerm writes empty
  and that set nothing. They exist only because libghostty answers the color-scheme
  query (DSR `CSI ? 996 n`, mode 2031) out of the *Config's* `_conditional_state`,
  and the only thing that moves it there is `Config.changeConditionalState`, which
  returns null unless `_conditional_set` contains `.theme`. That flag is set in one
  place: `Config.finalize`, when `theme` is a light/dark pair whose halves differ.
  Without the pair, `ghostty_surface_set_color_scheme` reports nothing and every
  pane claims to be light forever. Ghostty.app has the same bug on any config that
  sets its colors directly. The files are genuinely loaded, so they have to stay
  empty; only the two *paths* need to differ, since `finalize` compares the strings.
  The pair also moves `window-theme` off `auto`, which is inert here: only ghostty's
  GTK apprt reads that key, and the chrome never calls `ghostty_config_get`. So a
  surface's conditional state can differ from the app config's, which is the one
  place per-surface state is real (ZEN-307; ZEN-320 re-checks it on a pin bump).
- **Shader draw stops when nobody can see it.** The focus libghostty is told about
  is `paneFocused && isAppActive`, and `GhosttyHostView` reports its window's
  occlusion, so a backgrounded, covered or minimized window runs no shader draw
  timer at all (ZEN-271).
- **Teardown sweeps process sessions, not process groups.** libghostty sends
  `SIGHUP` to the shell's own process group, which misses every job the shell
  parked elsewhere: background jobs, children in their own process group (what
  `npm`, `turbo` and watchers do), `nohup`, `disown`. Those survived a closed tab
  and a quit (ZEN-269). `ShellSessionLedger` records every shell session the app
  starts; teardown sweeps the ones whose *leader has exited*, via
  `ShellSessionReaper` (`SIGTERM`, 150ms grace, `SIGKILL`, off-main).
  **Each leader is watched for its own exit**, with a kqueue process source armed
  when it is recorded. It used to be polled for inside a one-second window, which
  meant a leader slower than that was never swept at all: nothing rescheduled a
  look, so on the last pane its dev server outlived the close (ZEN-306). No
  duration is correct here, because a shell waiting on a foreground child exits
  when that child does. These leaders are the app's own direct children, so the
  kernel can name the moment instead.
  **A surface cannot name its own session.** libghostty forks the shell
  asynchronously under a setuid `/usr/bin/login` whose command line and
  environment the kernel hides, so neither fork order nor a planted env tag
  separates one surface's session from the next. A surface that guesses can adopt
  a sibling's and kill a live pane's work, so nothing attributes: freeing a
  surface closes its pty and takes that session's leader with it, and a leaderless
  session is by definition nobody's live pane.
  A consequence: `isBusy` still reads only OSC 133 prompt marks, because
  identifying *this* surface's background work would need the attribution above.
- **Quit drives window teardown by hand.** `windowWillClose` does not fire on app
  termination, so `applicationShouldTerminate` calls `tearDownForQuit()` on every
  window and waits on `ShellSessionReaper.drainForQuit` (capped) before
  replying. That waits for the shells to actually go, not merely for outstanding
  work to finish: at the moment the last surface is freed no leader has exited
  yet, so a drain watching only for idle sees none and lets the process go before
  a single signal is sent. Without any of it, quit frees no surface at all
  (ZEN-269).
- **`GHOSTTY_RESOURCES_DIR` is force-overridden.** Launching ZenTerm from inside
  Ghostty.app would otherwise inherit a mismatched version's shell integration and
  terminfo.
- **`isBusy` is `ghostty_surface_needs_confirm_quit`**, which means "the cursor is
  not at a prompt," from OSC 133 marks. A shell ghostty cannot integrate reads
  busy, conservatively.
- **Re-entrancy:** actions that make the chrome free a surface defer to
  `DispatchQueue.main.async`. Doing it synchronously inside `ghostty_app_tick` is a
  re-entrant use-after-free.
- **Every input event libghostty sees is an explicit `NSView` override.** There is
  no catch-all, so an event nothing overrides is dropped in silence rather than
  failing loudly. Modifier press and release (`flagsChanged`) and every mouse button
  past left and right were missing for exactly that reason (ZEN-308): the app looks
  completely normal, and the only thing that notices is a program inside the pane,
  running under the kitty keyboard protocol or with mouse reporting on. Modifier
  events carry which *side* moved, because AppKit reports the modifier state that
  resulted rather than the direction the key went: with both shifts held, the
  device-specific flags are the only thing separating a release from a second press.
  Ghostty's own app checks only the right-hand flags, so ZenTerm diverges here and
  checks whichever side the keyCode names, keeping Ghostty's fallback that an event
  with no side flag at all still reads as a press.
- **The sided modifier bits go on the key event and nowhere else.** libghostty
  stores its mouse mods as `Mods.binding()`, which strips the sides, then compares
  that stored value against whatever it is handed (`Surface.modsChanged`). A sided
  value can never equal a stripped one, so passing sides to the mouse callbacks
  leaves that guard permanently false and every key event and mouse move while a
  right-hand modifier is held marks the whole grid dirty and rebuilds every row.
  `ghosttyMods` is unsided for that reason and `ghosttySidedMods` is used only to
  build the key event. The same misfire already happens whenever caps lock is on,
  in ZenTerm and in Ghostty, because `binding()` strips the lock bits too.
- **Every modifier release is paired to a press the same surface reported.**
  `GhosttyHostView` records what it has told libghostty is down and forwards a
  release only for something in that record. Three ordinary paths emit an unpaired
  event otherwise: a preedit swallows the press but not the release after it, caps
  lock sets its flag both going down and coming back up, and a reserved chord that
  moves pane focus lands the press on one surface and the release on another, since
  `KeyInterceptor` consumes the chord's `keyDown` while `flagsChanged` passes
  through to whichever pane is first responder at the time. A release is still
  forwarded mid-composition, because libghostty is holding that press. Focus loss
  clears the record, matching libghostty releasing every held modifier there.
- **Only the focused pane is told a modifier moved.** `flagsChanged` is a
  responder-chain event, so it reaches the first responder alone. Ghostty adds a
  window-level monitor that fans it out to the other surfaces, which ZenTerm does
  not have, so an unfocused pane holds stale mouse mods until the pointer moves
  over it (ZEN-316).

### What the backend will and won't do

**`paste` is the real paste path, bracketed.** `GhosttySurface.paste` calls
`ghostty_surface_text`, which reaches `completeClipboardPaste(text, allow_unsafe:
true)`, the same path a real ⌘V takes. Two consequences for anything that types
into a terminal from the chrome: multi-line text arrives at a TUI as **one pasted
block**, not a run of Enter presses, so a multi-line message can be delivered
without prematurely submitting it; and it skips the unsafe-paste confirmation, so it
never stalls on a prompt the chrome doesn't render. To submit afterwards, send
`"\r"` as a **separate** `paste` call so the bracketed block closes first. There is
no dedicated bracketed-paste C API in `ghostty.h`; `ghostty_surface_text` is the
whole mechanism. Wired at `PaneCanvasController.pasteToSurface` and
`TabController.pasteToSurface`.

**Hyperlinks open on ⌘-click only.** ghostty's built-in URL link uses `highlight =
.hover_mods(ctrlOrSuper)`, so hover highlighting and click-to-open both require ⌘.
The I-beam over link text and a plain click doing nothing are correct, not bugs:
all terminal text is selectable, and plain click is reserved for cursor positioning
and selection. This matches Terminal.app and iTerm2.

**There is no per-pane user variable.** `OSC 1337 ; SetUserVar` cannot reach the
chrome: `GhosttySurface.handle(_:)` dispatches libghostty *actions*
(`GHOSTTY_ACTION_*`) and the xcframework header has no user-var action, and in
vendored ghostty `SetUserVar` sits in the unimplemented branch of
`osc/parsers/iterm2.zig`: it logs, marks the command invalid, and emits nothing.
Any "terminal keys off a plugin-set user var" design is dead here. App-side signals
from a pane process ride the **nav socket** instead (`$ZEN_SOCK` plus a per-pane
`$ZEN_PANE` token), which is how nvim panes are detected.

**Scrolling is whole-cell, and no shader can change that.** ghostty's renderer moves
the viewport in whole cells only: `Surface.zig` accumulates a sub-cell
`pending_scroll_y` remainder and truncates. There is no `smooth-scroll` config key,
and custom shaders are a post-process on the final frame with no scroll-offset
uniform and no frame history. The core also ignores the scroll momentum phase
entirely, so forwarding `NSEvent.momentumPhase` is inert and the macOS coast comes
from the OS's decaying deltas. The landing "stutter on rows" is that quantization
and is unfixable below the seam.

**Custom shaders get sRGB color, and gate opacity.** ghostty hands shaders the
cursor and color uniforms as **sRGB** (raw `/255`), and the pipeline is not linear,
so a shader that runs `sRGBToLinear(iCurrentCursorColor.rgb)` comes out nearly
invisible over text, so use the color raw. **A shader does not affect layer
opacity.** `layer.isOpaque` follows `behavior.isBackgroundSolid`, which is the
whole of `background-alpha` (ZEN-282), and nothing else. ZEN-188 once carved out an
exception dropping the layer out of opaque whenever a shader was on, against an
alt-screen white flash; ZEN-271 removed it, because that flash was root-caused by
reading the code and never reproduced, and the guard bought nothing (the window is
translucent below `background-alpha` 1 regardless, so the compositor blends it
either way). Only MIT-licensed shaders are bundleable:
`sahaj-b/ghostty-cursor-shaders`, `KroneCorylus/ghostty-shader-playground`,
`snedea/ghostty-themes`. The most-forked collection, `0xhckr/ghostty-shaders`, has
**no license** and un-attributed Shadertoy ports; `lexrus` water shaders are
personal-use only.

## The pane tree

`PaneKit`, six files, no AppKit, no global mutable state. Ids come from callers,
so everything is deterministic and testable.

```swift
public indirect enum PaneNode {
    case leaf(PaneID)
    case split(id: SplitID, axis: SplitAxis, ratio: Double, a: PaneNode, b: PaneNode)
}
```

`PaneTree` is a value type: every edit returns a new tree. `.vertical` means side
by side, `.horizontal` means stacked.

**How a running shell survives a restructure.** This is the core mechanism and it
has two halves:

1. `PaneSurfaceRegistry.apply(diff)` terminates removed leaves, creates new ones,
   and **touches nothing retained**. A retained leaf keeps its shell, scrollback,
   and first-responder state.
2. `PaneCanvasController.rebuildViews()` keeps `hostByLeaf` across the rebuild, so
   a restructure reparents existing hosts instead of rebuilding pane chrome.

The chain: `split()` mints ids and seeds the new leaf's cwd from the source's live
`currentDirectory`, then `tree.splitting(...)`, then `reconcileAndRender()`, which
diffs `registry.ids` against `tree.leafIDs` and applies.

`closing(_:)` returns **nil to mean "closed the only leaf"**, which is how the
caller knows to close the tab or window.

`PaneCanvasController` owns the tree, the registry, per-leaf state,
and is the `TerminalSurfaceDelegate` for every pane. Notable:

- **Zoom touches nothing.** `zoomedLeaf` only changes what `rebuildViews()` puts
  at the root. The tree, registry, and surfaces are untouched.
- **Resize swaps one constraint in place** so nothing detaches and focus survives
  key-repeat. It clamps using the split's *rendered* extent, which the pure tree
  cannot know. `minSplitExtent` is 240pt.
- `launchByLeaf` retains the exact config so `retryStart(id)` can replay it on the
  same surface after a failed start.

## Tabs and windows

`TabKit` is two pure files. `TabList` holds `order` + `activeIndex`, and its
invariant is that it **always holds at least one tab**: `close` returns false the
moment it would empty the list, at which point the caller closes the window.
`activeID` traps on an empty list, which is why every access in `WindowController`
goes through the nil-guarded `activeController`.

`WindowController` owns one window: its `TabList`, its
`TabController`s, the toast presenter, the tool floats, the single modal slot, the
tab bar, and the dock. `TabController` owns one tab: a
`PaneCanvasController` plus the two drawers.

**Inactive tabs are detached but retained**, so their shells keep running. Only
the active tab's view is mounted. The canvas mounts at the *back* of the container
(`.below, relativeTo: nil`) because it is the backdrop all window chrome sits on.

**Hidden drawers are detached, not `isHidden`.** A hidden view kept in the layout
collapses to 0x0, which resizes its PTY to zero columns and crashes size-sensitive
TUIs.

`TabID` is unique only within a window, so OS-notification identity is the
`(windowID, tabID)` pair. `windowID` is process-unique, monotonic, never reused.

**No native macOS tabs**: `tabbingMode = .disallowed`.

**Title polling.** Shells report cwd changes without OSC 7, so there is no push
event on `cd`. A 1.5s timer polls, and re-renders only when a title changed. The
same tick polls drawer busy state.

`tearDown()` is idempotent and is the single path for both the last-tab cascade
and the native close button. It cancels any pending confirm (or the app hangs
mid-quit) and ends any armed keybind capture (or the app-wide interceptor is
stranded in capture mode, swallowing every keystroke in every window).

## Chrome

| Surface | Owner | Scope |
|---|---|---|
| Bottom drawer, right drawer | `TabController` | per tab |
| Focus Mode (internally `zoom`) | `TabController` + `PaneCanvasController` | per tab |
| Fill Screen | `WindowController` | per window |
| Tool floats | `ToolFloatController` | per window |
| Settings, command palette, workspace picker | `WindowController.modal` | per window |
| Toasts, confirms | `ToastPresenter` | per window |
| Terminal font size | `SessionFontSize` | **per app** |

**Drawers are tiled, not floating.** The right drawer is a full-height column; the
bottom drawer sits under the canvas in the remaining left column, so the two never
overlap. Sizes are fractions applied as multiplier constraints, so a drawer stays
proportional through window resizes exactly like a pane. Every drawer constraint is
`.defaultHigh` rather than required, so a tiny window relaxes it instead of forcing
a negative canvas size.

Drawer animation resizes the canvas for real while the drawer **slides in at its
final size**, so its terminal reflows once and settles instead of jittering through
every row count.

**Focus Mode is strict.** While a pane or drawer is focused, split, nav, resize, and
drawer toggles are blocked with a toast rather than ignored. Order matters: relayout
to final size first, then pop. The internal identifiers stay `zoom` (`zoomedLeaf`,
`toggleZoom`, `Motion.zoomPop`) to stay distinct from the always-on pane-focus halo;
only the user-facing name is Focus Mode.

**Window chrome is config-driven.** The macOS window buttons show by default;
`window-chrome = false` hides them for a chromeless top, and `ChromeMetrics.topInset`
adds/drops the traffic-light clearance to match. **Fill Screen** (⌘⇧F) toggles the
window between its size and the screen's visible frame; it is a maximize, not native
fullscreen (no space switch, the menu bar stays).

**Modal cards share one slot.** `ModalKind` plus a single `modal` property. A chord
for a different card closes the current one and falls through, so cards switch
live.

**The diff viewer is the first chrome subsystem to shell out.** ⌘D opens
`DiffViewerOverlay`, a modal card over the focused tile: a single file tree on the
left split into three status sections (Unstaged → Staged → Committed, empty ones
hidden, each header carrying its slice's `+n −m` total), the diff of the selected file
on the right, and a full-width footer carrying the repo name + checked-out branch on the
left and the focus-scoped key hints (compact `KeycapView`s, the set narrowed to the pane
that holds focus) on the right. The diff renders in one of two layouts (`SideBySideDiff`
old │ new, or the inline `UnifiedDiff`), toggled by bare `\` and defaulted by the
`diff-layout` config key; both transforms feed one `DiffPaneTable` behind the
layout-agnostic `DiffRow` model. A narrow pane force-folds to inline (two columns stop
reading as code), where the `\` toggle is disabled and its footer hint hidden; a `\` pin
governs only the wide state. The committed slice forks from the repo's default branch
(`origin/HEAD`, else main/master; git records no parent, so a stacked branch's parent
isn't guessed). A static header above the tree carries a `Base: <branch>` `Dropdown`
(the same control the theme picker uses; branches default-first then by recency, the
checked-out branch excluded) that re-runs the committed slice against the chosen branch
and is reachable from the tree by arrow key or bare `b`. Navigation is vim-native and
local to the card (ZEN-262). ⌘h/⌘l move focus between the tree and the diff (the app's
own pane chords, forwarded from `WindowController.handle` since `KeyInterceptor` consumes
chords before the responder chain); everything else is a bare key the panes handle in
`keyDown`. In the tree, j/k step files, h/l (and ←/→) fold a directory or open a file into
the diff, Ctrl-j/k and Ctrl-↑/↓ jump the file selection half a page (centered), Ctrl-D/U
scroll the diff without leaving the tree, and b focuses the base. In the diff, j/k move the
cursor, {/} jump changes, 0/$ pan to the start/end of the line, Ctrl-D/U half-page, V
selects, y/Y yank, ⏎ comments, and h returns to the tree. `\` toggles the layout and q/esc
close from either pane. Because the bare keys aren't reserved, they pass through to the
terminal when the viewer is closed, and the
comment composer captures them as text while it's open, so no global chord is spent on a
view-only command. The footer legend scopes to the focused pane and leaves pane-switching
off (it's natural and discoverable, and it was the crowding the trim removed); bare `?` opens
the full key reference, so the legend can stay lean. That reference is a `ChromePopover` (a
composable primitive: caller supplies the trigger and the content, the popover owns the
themed chrome, the fade, and a click-outside backdrop) holding `DiffKeymapSheet`'s three
grouped columns, floated above the footer's trailing edge. The card wears the accent halo and the pane behind
yields focus, the way a configured tool float does.

**Selection is linewise, and vim-flavored.** Nothing typed inside the card reaches a
terminal, so the plain letters are free: `j`/`k` move, `V` starts a visual selection
anchored on the cursor, `gg`/`G` go to the ends, `{`/`}` reuse the change jump, and
`y`/`Y` (or ⌘C/⌘⇧C) yank the selected code or an `@path:42-44` reference (the `@` is the
file-mention token Claude Code resolves, so a pasted reference reads as an attachment). `DiffPaneTable`
tracks the cursor and the visual anchor itself rather than reading `NSTableView`'s
`selectedRow`, which reports the *last* index in the set: the anchor, not the cursor,
whenever a selection was extended upward. Esc is two-stage: it collapses a selection
before it closes the viewer. Character-level selection is deliberately absent: each line
renders as its own `NSTextField` inside a panned clip view, so charwise would mean
replacing that render path, and a diff reference is a line range regardless. Resolving a
selection is pure. `DiffSelection` reads the rendered `[DiffRow]` (either layout) into
the selected text plus a line range per side, and `DiffReference` renders the string. A
yank pulses the yanked rows and fades, the way nvim's `on_yank` does: a copy leaves
nothing on screen, so one that silently didn't take would look identical to one that did.
A re-render of the *same* file (the `\` toggle, or a resize crossing the fold band) carries the cursor
and selection over by their **line numbers**, never by row index: the two layouts index
differently, since side-by-side pairs the +/− lines inline lists separately.
Only the *new* side can be named, since that's the file on disk: a selection of pure
deletions references the new-side line it follows, and a deleted file gets a bare path.
The keys are view-local, not `ReservedChord`s, so they never enter the keymap and never
compete with a terminal binding.

**A selection becomes a comment, and the comment lands in a terminal.** ⏎ on the diff opens
`DiffCommentComposer`, an inline box that drops *into* the diff under the last selected line
(the anchor row grows by the box's height and the lines below shift down, a PR review comment)
so the code stays readable above it. It's a child of the pane, not a second `WindowController`
modal, which holds one slot. The box carries the `@`-reference implicitly, a `Dropdown` of the
tab's terminals (panes plus open drawers, focused one first so index 0 is where you were
working), and a note. ⏎ **submits** (paste the `@ref note` then a real Return, and the viewer
closes), ⌘⏎ **queues** (paste plus a newline, no submit, no focus steal, viewer stays open) so
several comments stack in one input before a final submit fires them together; ⇧⏎ is a literal
newline and esc closes just the box. Submit is a real Return keypress through the new
`TerminalSurface.submitLine()` seam, **not** a pasted `"\r"`: a pasted carriage return lands
inside bracketed paste, where a TUI reads it as a newline and never sends. The chrome never
reaches for a controller: the overlay takes the target list and the send as injected closures,
`TabController` owns `sendTargets()`/`send(_:to:action:)`, and the box hands back a finished
message and a chosen target. The note grows a line at a time past its default up to eight, then
scrolls; Tab walks note → Submit → Queue → target (right to left, so the first Tab lands on the
primary), while the footer claims no arrows so Left/Right keep panning the diff behind it.

**The viewer keeps your place.** A background refresh and a base switch both rebuild the
tree, and the `NSOutlineView` holds its rows by object identity, so the new objects can't
inherit the old ones' folds or selection. `DiffOutlineItem` carries a value `identity`
(section title + path) that survives the rebuild, and `apply` captures where the reader was
(folded rows, open file, cursor line) before the rebuild and restores it after: folds
re-close, the selection follows its file even when a `git add` moves it Unstaged → Staged,
and the cursor lands back on its line by number (never index). A directory a load is the
first to show comes up expanded, like any first-seen row. `DiffViewerSession` holds that
place plus the status cache, the highlight cache, and the picked base for the repo the
viewer last opened, so ⌘D reopens where you left off; it lives as long as the window and is
never written to disk, and a different repo starts fresh. The overlay snapshots the place
into the session on teardown (`viewDidMoveToWindow` with no window), not per keystroke.

Its git work is `GitDiffRunner`, the app's first real subprocess: `git diff` runs off
the main thread on a global queue, both pipes drained to EOF before `waitUntilExit`,
then back to main with a parsed `[FileDiff]`. The model half (`DiffParser`, `DiffTree`,
`SideBySideDiff`) is pure and renderer-agnostic; the overlay takes an injected loader,
so the chrome never touches `Process` and the whole surface is drivable in a test
without a repo. Opening is guarded upstream: a non-repo directory shows a toast and the
overlay never mounts, so it always has a repo. Like the palette and floats it has no
menu entry: chord + ⌘P + dock.

**Tool floats are window-level, not app-level**, because a surface is one `NSView`
and can live in one view hierarchy: an app-global instance would physically yank
the float out of window A when opened in window B. `ToolFloatController` holds no
reference to any `TabController` and reaches the active tab through four injected
closures. Liveness and visibility are independent: `activeFloat` is the one shown,
`liveFloats` are the ones alive.

**Every silent no-op is a toast.** Focus-Mode-blocked commands, dead nav directions,
git-guarded floats, ⌘W over a float. Both toast paths throttle at 3s per verb
because held chords auto-repeat.

**A surface that states current state needs a retraction written with the raise.**
A sticky toast, badge, or banner says what is wrong *now*, so fixing the cause has
to take it down; a warning that outlives its cause costs the same trust as a dead
control. When a command is gated off in some build configuration, make the off
state say so. Inert is fine, silent is not.

### The interaction language

New modal surfaces **compose the existing primitives** rather than re-implementing
the feel. Cohesion is the point: a bespoke button or divergent focus handling reads
as a different app.

- **Primitives:** `AppButton` is *the* labeled button (variants `primary` /
  `secondary` / `muted` / `destructive` / `segment` / `link`), and the confirm toasts use it
  too. `SegmentedControl` for pick-one, `FieldBox` + `LabeledField` for inputs.
  `ModalCard.swift` holds the card chrome and the shared scroll machinery.
- **Keyboard model, 2D.** ↑/↓ move between fields and sections; ←/→ move *within* a
  horizontal row (an env `KEY·value·✕` row, a segmented control, an Add/Cancel
  pair), boundary-aware inside text fields so mid-text arrows still move the cursor.
  Return advances, ⌘Return submits, Esc cancels. Each multi-control row is **one**
  vertical stop, anchored on its first element. Every card must be fully operable
  with no mouse.
- **Focus style.** Focused text inputs take the palette selection fill (accent at
  0.18) *plus* an accent outline; focused buttons and segments take the outline
  only. Drive input focus from the field's `becomeFirstResponder` and
  `controlTextDidEndEditing`: its `resignFirstResponder` does **not** fire, because
  the field editor is the real responder, so relying on it leaves every visited
  field stuck lit.
- **Validation** is per-field and inline beneath each field, never one shared error
  label. Required fields carry an accent ✳. The live pass flags bad input; the
  submit pass also flags empty-required fields and focuses the first offender.
- **Scrollable lists mirror the command palette**, via `ModalCard.swift`: a
  `FlippedView` document (`isFlipped = true`) plus `SlimScroller`, `scrollerStyle =
  .overlay`, `autohidesScrollers`. **The flipped document is load-bearing**: a
  plain `NSStackView` document view opens the list mid-scroll, with its origin at
  the bottom. Pin the document top/leading/width to `scroll.contentView` and inset
  the rows *within* the document. Do **not** use horizontal
  `NSScrollView.contentInsets` with `automaticallyAdjustsContentInsets = false`:
  nonzero left/right insets corrupt the clip view and the content spills out of the
  card unclipped.

**Motion constants are an approved baseline. Do not quietly re-tune them.**
`Sources/ZenTerm/Motion.swift` is the source of truth for the structural spring, the
entrance fade, and the halo and crossfade eases, and it documents each. The one
shape worth knowing here: the **entrance opacity is decoupled from the spring
settle**, because perceived snappiness comes from the card reading as present fast,
not from the near-invisible scale overshoot. Tying the fade to the spring's
`settlingDuration` makes the card linger.

## Key handling

**`KeyInterceptor` is a local `NSEvent` monitor**, app-wide, owned by
`AppDelegate`. It resolves and consumes chords **before the responder chain**. This
is the single most important thing to know when testing: a control's own `keyDown`
test can be green while the key never reaches it in the running app.

Order: capture mode (Settings recording) diverts and consumes everything, including
bound chords. Otherwise `flagsChanged` passes through, and `keyDown` bails
immediately if it carries no modifier (a reserved chord always has one) before
allocating a `Chord`.

**`Chord` canonicalization** is the sharpest rule in the codebase. A shifted glyph
folds onto its base key **only when Shift is set**, because
`charactersIgnoringModifiers` applies Shift: a live ⌘⇧- arrives as `_` while the
config spells `cmd+shift+-`. The Shift gate is load-bearing, not a formality: the
fold table is US-only, and `_` is unshifted on AZERTY. Folding on glyph alone would
give a keypress a Shift its user never held. **A non-US layout can at worst
mislabel a chord, never invent one.**

Defaults (`KeymapDefaults.map`): ⌘⇧\ and ⌘⇧- split, ⌘HJKL nav, ⌘⇧HJKL resize, ⌘W
close pane, ⌘T new tab, ⌘N new window, ⌘[ ⌘] tabs, ⌘1-9 select, ⌘B bottom drawer,
⌘\ right drawer, ⌘F Focus Mode, ⌘⇧F Fill Screen, ⌘P command palette, ⌘⇧P workspace
picker, ⌘, settings, ⌘⌥R reload, ⌘= and ⌘+ and ⌘- font size, ⌘0 reset it.
**No tool float is built in**; a float's chord comes from its own `key:` field.

**Increase ships two chords, and the second is load-bearing.** ⌘+ on a US layout is
physically ⌘⇧=, which `Chord` folds onto `=` because Shift is set, making it a
different dictionary key from bare ⌘=. Bind only ⌘= and the keypress most people make falls
through to libghostty, which still has it bound per surface, reproducing ZEN-224
for the common case. It is the one action with two defaults; `assemble` drops all of
an action's defaults on a rebind, and `Chord.displayed` sorts by config token, so a
keycap renders the plainer ⌘=. (ZEN-142 had moved split off bare ⌘- to leave it to
libghostty; ZEN-224 took it back, and ⌘⇧- stays split on its own merits.)

`KeymapAssembler.assemble` resolves defaults, then float chords, then user
keybinds, later winning. **A user keybind moves its action**: the action's default
chords are dropped first, so the old key is freed rather than both firing.

**The modal gate cascade** in `WindowController.handle(_:)` runs confirm, then
modal card, then tool float, then dispatch. The app-global chords (⌘N new window,
⌘⌥R reload config, the three font-size chords, and the unbound-by-default Check for
Updates command) bypass it on
the keyboard path (`AppDelegate.route`) and re-implement the gate by hand, because
they are app-global rather than window-scoped. A command-palette pick, though,
dispatches through `handle`, which forwards those same app-global chords back to
`route` via `WindowController.onAppGlobalCommand`. Without that they'd be a no-op in
`handle` (that's how Reload Config from the palette used to do nothing). Copy and
paste take a third path through the responder chain.

**The modal-card stage swallows, with one exception.** A card takes the window, so
every chord that is not its own toggle or another surface's toggle is dropped: a
palette, a form, or a confirm is mid-question, and acting on a chord behind it would
answer by walking away. The diff viewer is the exception for tab chords (⌘1-9, ⌘[,
⌘]), because it is a reading surface you live in rather than a question. It cannot
ride the switch the way a tool float does, since a card is tab-hosted
(`presentTileOverlay`) and unmounts with its tab, so it closes and the switch
happens. Each tab keeps its own `DiffViewerSession` (ZEN-298), so ⌘D on the far side
comes back where that tab left off.

**The float stage speaks rather than swallowing.** A pane command (nav, split,
resize, drawer, Focus Mode) pressed over an open float has nowhere to go, so it
raises a notice naming the float instead of doing nothing at all (ZEN-270). Held
chords auto-repeat, so it coalesces on a 3-second throttle, the same shape as the
zoom-block and no-neighbor toasts. It is not keyed by chord: the notice reads the
same whichever was pressed, so a second chord inside the window would only repeat a
card already on screen.

**The nav socket** backs [zen-navigator.nvim](https://github.com/zen-term/zen-navigator.nvim).
`NavSocketServer` listens on `~/Library/Application Support/ZenTerm/nav.<pid>.sock`
and exports it as `$ZEN_SOCK`. **Per-pid, not a well-known path**: a shared path let
a dev build bind over the installed app's socket and delete it on quit, leaving
every nvim deaf until relaunch. Failure is silent and non-fatal, because ⌘-nav never
depends on it. The wire contract is `docs/nvim-navigator-protocol.md`.
`NavGuard.shouldPassThrough` passes through only Ctrl-nav, never ⌘-nav, so default
pane nav is untouched whether or not the pane runs nvim.

Two things claim a Ctrl-nav chord ahead of pane nav: a pane running nvim, and **an
open tool float**, whatever it is running. A float is modal, so `handle` swallows nav
while one is up; consuming the chord took it from the tool and then dropped it, which
is how Ctrl-hjkl died inside an nvim float (ZEN-270). The float path needs no vim
check and no socket at all. A float mints no nav token and gets no `$ZEN_PANE`, so the
plugin inside one degrades to plain `wincmd`, which is the right behavior for a modal
surface with nowhere to hand off to.

## Config

Root is `$XDG_CONFIG_HOME/zen-term/` or `~/.config/zen-term/`, matching ghostty's
resolution. Four files: `config`, `workspaces`, `theme`, `themes/<name>`.

**Nothing here can crash the app.** A missing file yields the built-in default, an
unreadable one logs and falls back, a typo'd value falls back per key, and an
out-of-range number is clamped. Every adjustment logs one warning **and** collects a
`ConfigDiagnostic` (`configDiagnostics` on the resolved `GeneralConfig`), so the fallback
isn't silent: a stolen keybind or a bad scalar shows inline on the Settings row that owns
it, a bad sub-field on a surviving `float =` (its `width`/`height`/`order`/`persist`) on
that float's Tools row, a dropped `float =` line in the Tools-section notice (it has no
row), and a reload surfaces them all in one actionable toast whose "Open Settings" button
lands on the first problem's section.

**A fresh install writes nothing to disk.** `~/.config/zen-term/` does not exist
until the first save from Settings. There are no built-in tool floats and no
workspaces, so the ⌘⇧P picker shows only its `＋ Add workspace` row.
`ToolFloatCatalog.all` is `GeneralConfig.current.floats` and nothing else.

`docs/config/config` ships **fully commented out**, and `ReferenceConfigTests`
asserts that parsing it yields exactly `.builtIn`, so copying it is a clean slate.

**The terminal font size has a running value the file doesn't hold.**
`SessionFontSize.points` starts at the config's `font-size` and is what ⌘+ / ⌘- move
(whole points, libghostty's own increment) and ⌘0 returns to. It is app-global,
never persisted, and nothing writes it back: the file stays the thing the user
edits, this stays the thing they nudge. `font-size` and the stepping share one range
(`SessionFontSize.range`, 6…32) so one concept has one set of bounds whichever way
it is reached.

Two rules keep it honest, and both were silent failures without them:

- **The re-seed runs in `AppConfig.reload()`, before the broadcast**, not in an
  observer. `.configDidChange` observers run in registration order, so a window that
  re-applied first would push the pre-reload size. It re-seeds only when `font-size`
  itself moved (`reseedIfBaseChanged` compares the base value), because
  `ConfigChange.theme` subsumes every color and the font family too, so gating on the
  change set would throw a stepped size away whenever the user recolored the theme.
- **New surfaces are seeded, not just live ones.** `ShellLaunch` and
  `ToolFloatController` carry `SessionFontSize.points` in the spawn config, so a pane
  split after a step opens matched. Fanning a step out to what is already on screen
  is only half of ZEN-224; the next split lands at the config size otherwise.

**Live reload works because most call sites re-read.** `GeneralConfig.current` and
`Theme.current` are process-global mutable statics, and things like
`ChromeMetrics.panelGap` are computed properties that read them on every access.
The exceptions are already-built constraints and already-started shells, which is
exactly what `reapplyChromeLayout` and `applyAppearance` exist to fix up. **A
surface's shell is fixed for its life.**

`AppConfig.reload()` is the entire save-reload-apply seam, and its order is
load-bearing: general config first, then theme (which reads the general font), then
post `.configDidChange`. `GeneralConfig` reads nothing from `Theme`, so the one-way
dependency `Theme.current -> GeneralConfig.current` holds and they cannot deadlock.

Both statics start at the built-in default and are first resolved from disk by
`AppConfig.loadAtLaunch()`, in `applicationDidFinishLaunching` before any window
builds. That is a separate entry point from `reload()` because at launch there is
nothing to diff and no observer to broadcast to. Their initializers deliberately
no longer do the load. A Swift static is always lazy, so a
`= ConfigLoader.load…()` default ran a main-thread-only call on whichever thread
touched it first; initializing to a constant makes first touch harmless and moves
the load to one named place. See "Carbon and the main thread" in
`docs/swift-conventions.md`, which is now compiler-enforced.

**The broadcast names what moved.** `reload()` snapshots the config and theme
before re-resolving, diffs them, and carries a `ConfigChange` option set on the
notification, so each observer runs only the blocks whose config actually changed.
Settings live-apply is debounced at 180 ms, so typing in a numeric field posts about
five times a second, and the ungated fan-out relaid out every tab, recolored every
surface, and rebuilt the dock each time (~3.4 ms a post). Gated, a keybind rebind
costs 0.8 ms and a gutter edit 0.4 ms.

Those figures are **relative shape, not release timings**: they come from a debug
build driving a mounted `WindowController` (4 tabs, both drawers open) with stub
surfaces, so the per-surface `GhosttyConfigWriter.configText` cost sits outside
them. Treat them as which writes are expensive, not as what the shipped app
spends. The test target doesn't build under `-c release`, so a release number
needs Instruments against the real app.

**A notification with no change set reads as `.all`.** That fail-safe is the point:
too much re-apply is a wasted frame, too little is stale chrome, so a caller that
doesn't diff keeps the old do-everything behavior.

**Gate on what a call chain resolves, not what it is named after.** The
dependencies are not all obvious: `reapplyChromeColors()` reaches
`PanelHostView.reapplyTheme()`, which rebuilds the panel header's keycap from the
live keymap, so a rebind has to reach it as well as a theme swap, and re-reads
`background-alpha` to pick which of two arrangements paints the panel, so a
terminal-behavior change has to reach it too. An **open tool float** hangs off
the same fact for the same reason (`SurfaceFloatOverlay` hosts a terminal, so
the alpha governs its card too), and it is reached by a different branch, so
that one had to be widened separately. An open command palette re-renders
its rows the same way. Conversely the drawer fractions have no
live consumer at all (a built tab never re-reads them), so changing one does no
work. Before adding a kind or a call site, trace what it actually reads.

**Default to the union gate.** `.theme || .keymap` costs a fraction of a
millisecond, so a narrower gate needs a measured reason. Every bug the gating work
produced came from gating too tightly for no measurable gain: the win is skipping
the dock rebuild and the tab relayout, not shaving a keycap rebuild.

**Two entries deliberately do not gate on the kind sharing their name, and both
were regressions before they were comments.** `ConfigApplier` leaves
`surfaceConfigDiagnostics()` ungated, because it already has a finer,
delivery-aware gate: it records a notice as announced only once a window has shown
it, so gating on `.diagnostics` strands an undelivered notice forever. The update
card gates on `.theme || .keymap`, because `UpdateCardView.reapplyTheme()`
re-resolves its chord. Neither is untidy.

**The config-problems notice is retracted as well as raised.** It is sticky and
states what is wrong *now* rather than logging what happened at some past reload,
so fixing the config and reloading takes it down, and a changed problem set
replaces it instead of stacking a second card describing different problems.
Nothing else would: `ConfigDiagnostic.announcement` returns nil for an empty set,
which is indistinguishable from "nothing changed", so the warning used to outlive
the fix that made it false.

**Replacing a notice is all-or-nothing, and that is load-bearing.** Delivery can
fail, because the key window is not always one of ours (an open panel), so the
swap lives in `WindowController.deliverConfigDiagnosticsNotice`: it drops the
outstanding notice, across every window, only once one has been resolved to take
the new one. Retracting in `ConfigApplier` and announcing separately would take an
accurate notice down and then put nothing back, leaving a broken config with an
empty screen. `ConfigApplier` therefore retracts only when the problems clear,
which is the one case with nothing to put back.

That it is a static taking the window list, rather than a few lines inside
`AppDelegate`'s sink, is what makes it testable, and the ordering it encodes is
worth a test: reversing the sweep and the resolve passed the whole suite while it
was still inline.

**The app-global half lives in `ConfigApplier`, not in `AppDelegate`.**
`AppDelegate` is the `NSApplicationDelegate` singleton: it binds the nav socket and
builds windows at launch, and an observer registered inside
`applicationDidFinishLaunching` closes over private stored properties, so nothing
could drive it in a test. Both regressions above lived there. `ConfigApplier` takes
its collaborators as closures and `AppDelegate` wires the real ones.

**The gate is checked differentially, because review is not a safety net for it.**
The invariant is that for any config change the gated fan-out leaves the chrome
identical to the ungated one, and it is asserted by running both against the same
change and comparing a fingerprint of what is on screen
(`ConfigFanOutDifferentialTests`, `ConfigApplierDifferentialTests`). That catches
a too-narrow gate without anyone having to enumerate a four-deep call chain
correctly, which is what failed twice in one sitting. Two limits are real: the
comparison only covers what the fingerprint samples, and it cannot see a bug that
breaks the gated and ungated paths equally, which is why the named per-probe tests
in `WindowControllerConfigFanOutTests` stay alongside it.

**External hand-edits are picked up on demand only, via ⌘⌥R. There is no file
watcher.**

Both writers do a whole-file read-modify-rewrite over `ConfigFileIO`, which
centralizes two guards: never treat an unreadable existing file as empty (the
rewrite would erase the user's config), and write through symlinks (a config
symlinked into a dotfiles repo must keep pointing there). `ConfigWriter` preserves
comments, blank lines, and unknown keys verbatim.

**Theming is derived, never hardcoded.** `ChromeThemeDeriver` maps ANSI slots onto
sixteen chrome roles. Nine carry chrome meaning: background and foreground come from
the theme's own, info is ansi[4], warning ansi[3], destructive ansi[1], accent ansi[5],
attention ansi[6], positive ansi[2], and muted a blend of fg and bg. The other seven
are the diff viewer's syntax roles, resolved through `SyntaxRole`: synKeyword ansi[5],
synString ansi[2], synNumber ansi[3], synType ansi[6], synFunction ansi[4],
synPunctuation ansi[1], and synComment a fainter fg/bg blend than muted.

Roles are named for meaning, not hue, so several share a slot: accent and synKeyword
are both ansi[5], info and synFunction both ansi[4]. That is why the roles are
separate fields rather than one alias, and why repointing one leaves the others alone.
Fifteen themes ship bundled; a user file shadows a bundled one of the same name. See
CLAUDE.md for the rule that the chrome never hardcodes a color.

**A program can move one color, and only inside its own pane.** OSC 11 (and OSC 4/10/12) is
applied by libghostty *below* the seam. It writes the color into `terminal.colors` and its
renderer draws from there, so the grid follows a program whether the chrome reacts or not,
and there is no config key to stop it. What the chrome decides is how far that reaches
(ZEN-23). `GHOSTTY_ACTION_COLOR_CHANGE` is the notification that lands afterwards, and the
background alone is carried up, as `surface(_:backgroundDidChange:)` plus the
`backgroundOverride` pull for a host built after the fact. It repaints the fill that pane
paints around and under its own terminal (`PanelHostView`, `SurfaceFloatOverlay`, and the
layer behind the grid), so a repainted pane doesn't sit inside a ring of the old color.
Every `ChromeTheme` role stays `Theme.current`: a program recolors its pane, never the frame
around it. Foreground, cursor and palette changes are dropped, because the terminal draws
those and no chrome surface repeats them.

**The reported color is mirrored as-is, a reset included**, which is not the obvious choice.
An OSC 111 reset arrives as an ordinary change carrying the theme's own background, so
recognising it and dropping the override reads as the tidy move. It is wrong: libghostty's
`DynamicRGB.reset` is `override = default` rather than `override = null`, and
`Termio.changeConfig` then writes `default` alone, so once a program has touched OSC 11 the
grid is pinned to a concrete value no later theme change can move. Dropping the override
would walk the chrome off a grid that stayed put. Mirroring keeps the pane matched to its own
terminal in every order.

**Two gaps live below the seam and cannot be closed from here.** A theme change after any
OSC 11 leaves that surface on the old background while the rest of the chrome moves, because
libghostty never re-reads its `override`. And the kitty color protocol (OSC 21) writes
`terminal.colors` with no `color_change` emitted at all, so an OSC 21 reset moves the grid
with nothing the chrome can observe. Both need a backend fix, not a chrome one.

**`accent` is the one role the user can repoint.** It is the chrome's primary and
is read live at every focus, active, and confirm surface, so `accent-color` in the
config sends all of them at once by naming an `AccentSlot` (an ANSI hue name, ZEN-255).
The override is applied to the `accent` field alone inside the deriver, so the roles
that carry meaning stay put: a warning is not a taste. What makes this work with no
call-site changes is that nothing caches the color: `ConfigChange.between` sets
`.theme` from a whole-value `AppTheme` diff, and the existing `reapplyTheme()` fan-out
repaints even the sites that bake their color at init, like the tab bar's tracer.

The syntax roles do not follow it (ZEN-301). `synKeyword` derives from the same
`slot(5)` the accent defaults to, so out of the box the chrome's primary and the diff
viewer's keywords are the same color by coincidence. Repointing the accent leaves the
code where it is: a keyword is a token role, not a taste. `ChromeThemeDeriverTests`
asserts it, because the coupling is otherwise invisible.

## Invariants that will bite you

- **Closures capture by id, never by object.** A closure stored on a controller
  that captures the controller retains it forever.
- **Unified focus is chrome-owned, not AppKit's.** Exactly one panel per tab holds
  the halo and first responder. `TabController.focusedPanel` is the source of truth
  and is pushed explicitly.
- **`HostWindow.isReleasedWhenClosed = false`.** Without it AppKit also releases the
  window on close, underflowing the retain count and crashing in the close-time
  CoreAnimation commit.
- **`ShellLaunch.program` re-arms zsh's `ZDOTDIR`.** libghostty injects shell
  integration by pointing `ZDOTDIR` at its own directory and restores the user's
  before their rc files run, so an `exec`'d shell is not injected: no OSC 7, cwd
  frozen at the seed forever, prompt marks never fire, `isBusy` breaks. The re-arm
  restages the redirect.
- **`GitRepo.repoRoot` terminates on the path not shrinking**, not on
  `parent == dir`. `deletingLastPathComponent()` is not monotonic on a
  FileManager-vended URL: it walks past `/` forever, and an equality check spins the
  main thread.
- **The `workspaces` file is read off the main thread, so its readers render
  twice.** `ConfigLoader.loadWorkspaces` has a completion-handler form that every
  caller uses; the synchronous form behind it is the parse step, and calling it
  from the main thread is the stall this removed. Path validation runs on its own
  queue *after* the list has been handed over, so the card never waits on a `stat`
  and a hung mount can't hold up the next load.

  **A card that renders from it is built after the load, not filled after
  presenting.** The list height sizes the card, so entries landing a frame late
  resize it mid-spring and the open reads as a flash; and a form's
  title-collision check seeded with half the titles would accept a duplicate. So
  the press and the card are two turns of the main queue, and `pendingModal` is
  the card's only trace in between: a second press toggles it off, and
  `presentModal` clears it so a card going up can't be landed on by one still
  loading. Settings → Workspaces is the one that does render twice, and it shows
  neither rows nor its empty-state hint until the load lands, because that hint
  is the answer for an empty *file* and flashing it mid-read reads as "your
  workspaces are gone".
- **Interactive git probes go through `GitRepoStatus`, never `GitRepo` directly.**
  Both are filesystem I/O, which the main queue never blocks on: the ⌘⇧P picker and
  Settings → Workspaces render their badges from `GitRepoStatus.known` (nil until
  something has probed) and turn them on when a `refresh` lands, and a tool float
  resolves its repo root through an injected async probe, and only when its `git:`
  guard or `.directory` anchor actually needs one. Refreshing per open, rather than
  answering once per process, is what shows a freshly `git init`ed folder's badge
  without a relaunch.
- **A tool float's open is cancellable while its repo-root probe is out.** The
  walk is off-main, so a `git:`-gated or `.directory` float opens a queue hop
  after the press, and for that window `pendingOpen` is the float's only trace:
  `activeFloat` is still nil, so a close, a tab change, a config prune, a modal
  card going up, or a second press of the same chord all have to reach it through
  `cancelPendingOpen()`, which bumps the generation the probe's completion checks.
  A float needing neither the guard nor an anchor skips the probe and opens
  synchronously. The cwd is read once at the press and carried into `spawn`, so a
  persistent float's anchor and its shell's directory can't disagree.
- **A palette row is reused, so it never carries an index.** `PaletteOverlay`
  re-renders per keystroke and keeps the view of every row whose `rowIdentity`
  survived the filter, so the base rebinds each row's `onActivate` on every load and
  a live theme change discards the rows outright (a row bakes its colors in at
  construction). The list's order is its stack's ARRANGED subviews; a reused row keeps
  its old place in `subviews`.
- **Swift's sort is not stable**, so floats sort by `(order, lineIndex)`.
- **Never block the main thread.** See CLAUDE.md.

## What does not exist

Do not describe these as features, and do not assume them when reading:

- **No left sidebar.** Two drawers: bottom and right.
- **No second backend.** libghostty is the only one. The DEBUG-only `makeOverride`
  seam exists for headless test stubs.
- **No built-in lazygit, gitdash, or any built-in tool float.** Every float is a
  user-authored `float =` line.
- **No web panes.** Every leaf is a `TerminalSurface` over a PTY.
- **No session or layout restore.** Nothing persists the pane tree, tab list, or
  window frames. Every launch is one tab, one pane.
- **No session persistence, and it is not coming.** Detaching the GUI and
  reattaching running sessions (the tmux/screen affordance) is deliberately off the
  roadmap. ZenTerm embeds libghostty exactly as Ghostty.app does: one process, one
  shared `ghostty_app_t`, N surfaces each being one PTY, one shell, one grid. Panes
  die with the process, same as kitty or ghostty. It is the one feature that would
  argue for a fundamentally different substrate (a multiplexer underneath), so
  don't propose it or design around it. **The bet is that the chrome is the moat**:
  hideable per-tab drawers, floats, and the UI itself are things no mainstream
  terminal ships, and they are only possible because the terminal core is a rented
  drop-in behind the seam. The cost to watch is integration parity at that seam
  (IME, input, rendering) and transparent-window GPU friction, not per-pane process
  cost, which is a non-issue.
- **No smooth scroll.** The viewport moves in whole cells and nothing below the
  seam can change that. See "What the backend will and won't do".
- **No tab drag-to-reorder**, no config file watcher, no scrollback search.
- **Two seam events are emitted with zero consumers**: `surfaceDidRingBell` and
  `progressDidChange`. The backend translates both, but nothing in the chrome
  implements them. Pane exit runs entirely through `surfaceDidExit`.
