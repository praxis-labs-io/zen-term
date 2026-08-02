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
`setFontSize`, `scroll`, and it reports its grid geometry as `cellMetrics` so the
chrome can draw on the grid rather than near it. It also reads its own screen back, a
row at a time for motions (`text(viewportRow:)`) and a span at a time for a yank
(`text(in:)`), which differ in whether soft-wrapped rows come back joined.

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

⌘-hover also raises `MOUSE_OVER_LINK`, which crosses the seam as
`surface(_:hoveredLinkDidChange:)` and mounts a `LinkPreviewView` near the pointer
(`LinkPreviewPresenter`, ZEN-24), so underline, pointer cursor and URL preview
appear together. Plain-hover underlining was considered and declined: the highlight
condition is hardcoded per link and the `link` config that could change it is
unsettable upstream, and since highlight is also what makes a link clickable
(`src/input/Link.zig`), plain-hover underline would make bare clicks open links.
Changing that means a carried vendor patch, judged not worth it.

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
tab bar, and the footer toolbar (`ToggleDock`). `TabController` owns one tab: a
`PaneCanvasController` plus the two drawers.

**Inactive tabs are detached but retained**, so their shells keep running. Only
the active tab's view is mounted. The canvas mounts at the *back* of the container
(`.below, relativeTo: nil`) because it is the backdrop all window chrome sits on.

**Shell command completion is a background-tab signal.** libghostty decodes OSC 133 and emits
`GHOSTTY_ACTION_COMMAND_FINISHED`; `GhosttySurface` converts its signed exit-code sentinel and
nanosecond duration into `TerminalCommandResult`, then panes and drawers relay it through their tab.
Commands under 10 seconds stay quiet, as do commands in the active tab. A longer command in a
background tab marks the tab number with the theme's positive color and raises one sticky result
toast with Dismiss and Switch actions. A later agent notification replaces that completion state;
command completion never replaces an agent request that still needs attention. Selecting or closing
the tab clears either state.

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
isn't guessed). A static header above the tree carries two stacked `Dropdown`s (the same
control the theme picker uses). They stack, so focus steps through them vertically: Up
from the tree's top row reaches the lower of the two, Up again reaches the upper, and
Down walks back. Bare `b` still lands on the base picker and Tab still steps between
them. Each hop falls through to whatever is actually showing, so a repo with no resolved
base doesn't swallow Up and strand the branch picker on the mouse.
`Base: <branch>` re-runs the committed slice against the chosen
branch, ordered default-first then by recency. `Branch: <name>` picks what is being
*read* rather than what it is measured against (ZEN-313), ordered checked-out-first.
They stack rather than sharing a row because both hold unbounded branch names: split one
row between them and both truncate while the card is held open. Both set
`titleTruncatesUnderPressure`, so the pickers yield their width instead of driving the
tree column's.

**Neither picker offers the other's selection.** A branch is never comparable to itself,
so the base list hides the selected head and the head list hides the selected base, each
keeping its own selection so picking can't remove what you just picked. Both exclusions
live in `DiffViewerOverlay` because only it knows both, and both move as you pick.
`GitDiffRunner.orderedBranches` used to drop the checked-out branch for this reason; it
excludes nothing now, since once a head is selectable it is the *selection* that decides,
not the checkout. Picking rebuilds the header immediately rather than waiting for the
load, because a reload landing an identical status is a deliberate no-op (ZEN-233) and
would otherwise strand both pickers on the old pair.

**A picked branch is read two different ways.** One with a worktree is a real checkout on
disk, so `WindowController` builds a second `GitDiffRunner` rooted at that path and all
three slices stay live. One without exists only as commits, so the pinned runner answers
with the branch as its head, the two working-tree slices come back empty by definition,
and the list marks it `committed only`. Which case applies is the host's call, not the
overlay's, which is why the whole `BranchOption` crosses the loader seam rather than a
name.

**Two different things move, and both have to.** For a branch with no worktree the *ref*
moves: `FileDiff.headRef` carries it down so a committed-slice blob is fetched from the
branch the diff was computed against. For a branch with one, the *root* moves instead, and
the highlighter reads blobs on its own path (`DiffHighlighter.enrich` plus the prefetcher's
background pass) rather than through the loader. So `DiffViewerOverlay.retargetRepoRoot`
repoints its root and rebuilds the prefetcher on every pick, and clears
`DiffHighlightStore`, whose keys carry no notion of which root produced them. Miss that and
the diff is right while its colours come from another branch's file contents, and a file
added on the picked branch caches a nil span set and renders plain forever.

**The branch lists refresh on every load, ahead of the unchanged-status guard.** That guard
exists so an identical diff repaints nothing (ZEN-233), but it says nothing about whether
branches were created or deleted. Gated behind it, a picker could name a branch that no
longer existed until some unrelated edit happened to change the diff. A refresh also
re-resolves any override by name, so a deleted branch or a moved worktree drops the
selection rather than leaving the picker showing one branch while the loader is asked for
another. An empty listing is treated as a failed read, not as proof the branch is gone. Navigation is vim-native and
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
viewer last opened, so ⌘D reopens where you left off; it lives as long as the tab and is
never written to disk, and a different repo starts fresh. The overlay snapshots the place
into the session on teardown (`viewDidMoveToWindow` with no window), not per keystroke.

While the card is open, `WindowController` owns a recursive `RepoWatcher` on the effective
repository root. Picking a branch in another worktree retargets the stream along with the
loader and highlighter. A linked worktree's `.git` pointer does not sit above its index,
`HEAD`, or shared refs, so the watcher resolves its `gitdir` and `commondir` and adds both
external metadata roots to the stream. FSEvents delivers working-tree and Git metadata changes
on the watcher's utility queue; a trailing debounce coalesces each write burst, then the settled
edge asks the overlay to refresh on main. Status loading is single-flight: events during an
active load collapse into one trailing load instead of stacking Git subprocesses. Each current
result refreshes branch metadata once and treats an unchanged status as a no-op, so ignored-file
churn costs a Git read but no rebuild. If the selected worktree disappears, branch reconciliation
returns the watcher and reader to the original checkout, then reloads there so the base, tree, and
footer cannot remain stranded on the deleted branch. Closing the card or its window stops the
stream and invalidates any pending edge before teardown continues.

Its git work is `GitDiffRunner`, the app's first real subprocess: `git diff` runs off
the main thread on a global queue, both pipes drained to EOF before `waitUntilExit`,
then back to main with a parsed `[FileDiff]`. The model half (`DiffParser`, `DiffTree`,
`SideBySideDiff`) is pure and renderer-agnostic; the overlay takes an injected loader,
so the chrome never touches `Process` and the whole surface is drivable in a test
without a repo. Opening is guarded upstream: a non-repo directory shows a toast and the
overlay never mounts, so it always has a repo. Like the palette and floats it has no
menu entry: chord + ⌘P + toolbar.

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

Order, all of it in `KeyInterceptor.route(_:)` (factored out of the live monitor so
it is unit-testable, the same reason `resolve(_:)` is): capture mode (Settings
recording) diverts and consumes everything, including bound chords. Otherwise
`flagsChanged` passes through; a `keyDown` carrying no modifier skips chord
resolution without allocating a `Chord`, because a reserved chord always has one.
Whatever no chord claimed is offered to `modeHandler`, and only then to the PTY.

**`modeHandler` is the sticky-mode hook, and it sits *below* chord routing.** That
placement is the design: a mode installed above it would swallow ⌘T, ⌘P and pane
nav for as long as it was up. Below it, a mode still gets every un-reserved key,
including the bare `j`/`k`/`g` that no chord is allowed to hold, while the user's
own binds keep working inside the mode. It is installed only while a mode is live,
so an idle app pays one nil check per keystroke.

**`Route` distinguishes two ways of not consuming**, and collapsing them is a real
bug rather than a tidiness question. `passThrough` means nothing claimed the key, so
a mode may still take it. `deferToTerminal` means a chord *did* match and
`passThroughGuard` handed it to the program on purpose (`Ctrl`-nav over an nvim
pane), so nothing else may touch it. With one case, scroll mode ate the `⌃j` that was
being handed to nvim, and the key did nothing at all.

**A mode declines what the menu owns.** The monitor is local, so it runs before
`NSApp.sendEvent` resolves menu key equivalents, and ⌘C/⌘V/⌘Q are menu items rather
than reserved chords. A mode that consumed every unmapped key killed Copy and Quit
for as long as it was up. A mode consumes an unmapped key only when it carries no
⌘ or ⌥, which is exactly the set that would otherwise reach the shell as input.

**`Chord` canonicalization** is the sharpest rule in the codebase. A shifted glyph
folds onto its base key **only when Shift is set**, because
`charactersIgnoringModifiers` applies Shift: a live ⌘⇧- arrives as `_` while the
config spells `cmd+shift+-`. The Shift gate is load-bearing, not a formality: the
fold table is US-only, and `_` is unshifted on AZERTY. Folding on glyph alone would
give a keypress a Shift its user never held. **A non-US layout can at worst
mislabel a chord, never invent one.**

Defaults (`KeymapDefaults.map`): ⌘⇧\ and ⌘⇧- split, ⌘HJKL nav, ⌘⇧HJKL resize, ⌘W
close pane, ⌘T new tab, ⌘N new window, ⌘[ ⌘] tabs, ⌘1-9 select, ⌘B bottom drawer,
⌘\ right drawer, ⌘F Focus Mode, ⌘⇧F Fill Screen, ⌘⇧S scroll mode, ⌘P command
palette, ⌘⇧P workspace picker, ⌘, settings, ⌘⌥R reload, ⌘= and ⌘+ and ⌘- font size,
⌘0 reset it.
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

### Scroll mode

⌘⇧S reads back through the focused panel's scrollback from the keyboard.
`ScrollModeController` owns it, one per window, and it targets whichever panel held
unified focus when it opened. It does not follow focus afterward.

**It exists because the keys that should scroll a buffer are the shell's.** `j`,
`k`, `⌃d` and `⌃u` cannot be reserved chords without taking them from every program
in every pane, and libghostty's own ⌘Home/⌘PageUp defaults (live in ZenTerm, since
the chrome never claims those chords) are fn-chords on a laptop that nothing in the
UI mentions. A mode borrows the keys while it is up and gives them back on exit.

`command(for:afterG:)` is a pure static over `NSEvent`, the same testable seam as
`DiffPaneTable.vimKey(for:)`, and it reads shiftedness from the modifier flags
rather than character case for the same Caps Lock reason. j/k step the cursor, h/l move
a column, w/b/e move by word, 0/$ reach the ends of a row, ⌃d/⌃u move a half page, ⌃f/⌃b
and space a page, gg/G the ends, { and } move by paragraph, v/V select, y copies, and
Esc/q/i leave. **Every key is consumed, mapped or not**: passing misses through would
drop a stray keystroke into the shell behind the mode, which is worse than one that
does nothing.

**The cursor is the chrome's, drawn on the pane.** libghostty has no copy mode and no
cursor outside the shell's own, so `ScrollCursorView` paints the band on the current row,
a stroked cell where the cursor is, the selection rects, and the yank pulse, added last
inside `PanelHostView.clip` and pinned to the terminal view rather than to the clip, so
its row math is in the surface's own coordinates. It returns nil from `hitTest`, because
the thing behind it is a live terminal that still has to take clicks and drag-selection.
The cursor cell is stroked rather than filled: a real terminal cursor inverts its cell,
an overlay cannot, and a fill solid enough to read as a cursor takes the character with
it.

Geometry comes from `TerminalCellMetrics`, which `GhosttySurface` reads out of
`ghostty_surface_size` **at draw time, never cached**: the row height moves with the
font size and the row count with every resize. Two conversions matter. Every `_px`
field is in the backing pixels the chrome pushed through `ghostty_surface_set_size`,
so it divides by the backing scale to get points. And the grid does not start at the
view's origin: libghostty insets it, leftover space that doesn't divide into a whole
cell collects at the *far* edge, and `GhosttyConfigWriter` now emits
`window-padding-x/y` explicitly rather than inheriting a default that could move on a
pin bump and put every band a row out of true.

`j`/`k` are `.step(±1)`, not `.scroll(.lines(±1))`, and the distinction is the feature:
the cursor moves for the height of the viewport and the buffer only moves once the
cursor is pinned at an edge. Scrolling on every `j` would drag the whole screen to
track a marker that never moved.

**The mode opens on the last written row of the viewport**, found by reading rows from
the bottom up. Not the bottom of the pane, which on a half-filled screen is empty space
below everything there is to read, and not the shell's cursor: `ghostty_surface_ime_point`
reports that against the *live* screen with no account of scrolling, so a viewport the
reader had already scrolled with the wheel put the band on an unrelated row.

**The header goes up before the grid is measured.** A pane's header is hidden until a
mode shows it, and showing it moves the content's top constraint down by its height, so
the terminal loses a row or two and reflows. Measuring first put the band a row off the
prompt, which is subtle enough to look like a rounding error in the cell math and is not
one.

**A move that names a destination puts the cursor on it**, rather than bringing it into
view and leaving the cursor elsewhere. `gg`/`G` carry it to the ends.

`{`/`}` are the chrome's own motion, not a backend call, and they have to be. libghostty's
`jump_to_prompt` scrolls the viewport to a prompt **above** the screen, so it cannot reach
any prompt you are looking at, and in a pane with no scrollback it does nothing at all while
three prompts sit on screen. `ghostty.h` exposes no prompt marks (only a window-title action),
so moving a cursor to a prompt is not expressible. Vim's `{`/`}` key off blank lines anyway,
which are readable, and in a terminal a blank line is what separates one command's output from
the next.

So the motion walks the viewport: step past any blank rows the cursor already sits in, cross
the block of text, land on the blank after it. `TerminalSurface.text(viewportRow:)` reads one
row per call, because `read_text` goes through `selectionString` with `unwrap = true` and a
multi-row read comes back as logical lines with the row index no longer matching. The walk
stops at the first blank, so it is a handful of reads rather than one per row. Clamped to the
viewport: a paragraph off-screen needs the buffer moved first, which is what the page keys do.

A page move is the other case: it carries the cursor with the viewport, so your place on
screen is kept.

#### Selection and yank (ZEN-331)

`v` and `V` anchor a selection at the cursor; motions grow it; `y` copies it, drops back
to normal mode, and pulses what it took the way `DiffPaneTable.flashYank` does. The pulse
runs after the write, not on the keystroke, because a yank leaves nothing on screen and a
copy that silently didn't take looks identical to one that did. `Esc` hands the selection
back before it closes anything, which is the diff viewer's rule too.

`ScrollSelection` holds the **anchor only**. The cursor lives on the controller, which owns
it in normal mode as well, and a second copy would be one to drift: every motion would have
to write both, and the one that forgot would draw a selection ending where the cursor is
not. `range(to:columns:)` orders the two ends, and orders `.line` itself rather than leaving
it to `TerminalViewportRange`: that init pairs each row with the column it arrived on, so
handed (row 10, col 0) and (row 5, col 79) it would swap the columns along with the rows.

`ScrollWordMotion` is vim's `w`/`b`/`e` over a row reader, with `iskeyword` at its default
so `foo.bar` is three words. **A word never spans a row break**, even where the classes line
up, or a `w` from `two` in `one two` runs clean past `three` on the row below.

**A selection cannot leave the viewport, and no design choice makes it possible.**
libghostty resolves an exact coordinate through `Point.pin`
(`vendor/ghostty/src/apprt/embedded.zig`), which does `@min(self.y, screen.pages.rows -| 1)`
for **every** point tag, `screen` included, and `pages.rows` is the grid height rather than
the scrollback total. So no coordinate names a scrollback row, and text off screen cannot be
read. A selection that outlived a scroll would highlight rows it no longer covers and yank text the
reader never saw, so the anchor comes back the moment the rows move. That is driven by the scrollbar
report rather than by the key that asked, because the two do not line up in either direction: output
moves the viewport with no key at all, and a `j` at the end of the buffer moves nothing while looking
exactly like one that does. A reflow releases it directly, since the cursor can be found again by its
line and a fixed anchor cannot.

The other limit is columns. `read_text` hands back a string with no per-character cell
mapping, so a column is a character offset into the row's text. A wide character (CJK, an
emoji) fills two cells while counting as one offset, so the cursor cell sits one to the left
of true for each one earlier in the row and a yank ending past one stops short of what was
highlighted. ZEN-349 carries the width-aware model that closes both.

A row's trailing blanks come off in `rowText`, not in the backend. `Surface.dumpTextLocked`
reads with `.trim = false` and the formatter keeps every cell a program actually painted, so a
row filled edge to edge (a prompt with a right segment, a status bar) arrives padded to the grid
width. Left on, `$` parks the cursor out in the padding and `v$y` copies a run of spaces.

### Scrollback search (ZEN-324)

⌘/ opens a find bar along the bottom of the focused panel. **The searching is
libghostty's**: it matches, counts, tracks which match is selected, and its renderer
paints every highlight. `SearchController` owns the bar, the needle, and the keys, and
that is all the chrome does here.

Three binding actions go down (`search:<needle>`, `navigate_search:next|previous`,
`end_search`) and four actions come back up (`START_SEARCH`, `SEARCH_TOTAL`,
`SEARCH_SELECTED`, `END_SEARCH`), relayed through one `onSearchEvent` closure rather
than four so the walk through the pane and tab controllers stays one line. The needle
needs no escaping: libghostty splits a binding action on its **first** colon and takes
the rest verbatim. `performBindingAction` grew a `logsFailure` flag because three of
these legitimately return false, meaning "there was nothing to do" rather than
"rejected". `START_SEARCH` is handled even though the chrome never sends it: libghostty's
own search-the-selection keybind is live in every surface and would otherwise do nothing.

**A match only in history is previewed while you type**, by stepping once when the
viewport holds no occurrence and the total is above zero. Without it the bar counts
matches over a screen showing none of them and Return is pressed on faith. It does not
run when a match is already visible: stepping then pulls the screen off the answer
already in front of the reader, which is the part of vim's `incsearch` worth leaving
out. Once per needle, because `SEARCH_TOTAL` fires repeatedly as the engine works back
through the buffer. `commit` then skips its own step when a preview already selected
something, or ⏎ would walk straight past the match being looked at.

**Search leaves behind only what it started.** Committing brings scroll mode up on the
reader's behalf, so Esc takes it back down: one keystroke to find something, one to be
done with it. A reader already in scroll mode when the bar opened put themselves there
and keeps it, which is what `didStartScrollMode` tracks.

The viewport is put back the same way. Stepping is the only thing here that moves it, so
`didMoveViewport` gates a `scroll(.bottom)` on the way out and again whenever a needle
stops matching: one character past the last match leaves the pane parked on the previous
needle's answer with nothing on screen matching what is now typed. Neither fires for a
search that never moved the viewport, and neither fires while the reader is being left in
a scroll mode of their own, where the match is what they asked to be shown.

**The keyboard runs in two phases, and the gate between them is load-bearing.** While
the field holds first responder, `updateModeHandler`'s closure returns false for
everything. `KeyInterceptor` is a local monitor running ahead of the field editor, so a
mode that kept claiming keys would eat the typing and leave the bar untypeable while
looking exactly right. ⏎ hands first responder back, brings scroll mode up, and phase two
claims `n`/`N`/⏎/⇧⏎/Esc through `SearchController.key(for:)` rather than through
`ScrollModeController.Command`, which keeps that enum closed and lets search work whether
or not scroll mode was ever entered. Both modes share the one `modeHandler` slot.

The bar **displaces** the terminal the way the header does at the other end, so opening
and closing it reflows the grid. Both paths run the same order: change the constraint,
`layoutSubtreeIfNeeded`, then `refreshGeometry`. Measuring first reads the grid that is
about to change out from under it.

**Why the cursor cell is inferred rather than read.** `SEARCH_SELECTED` carries an index
and nothing else (`vendor/ghostty/src/Surface.zig`): the match's geometry goes to the
renderer thread's mailbox and never crosses the C API, and `Screen.selection` is untouched,
so reading the selection back gets the mouse drag. There is no API for the position. So
`matchCell` reads the viewport back and looks for the needle, using direction alone:
libghostty walks matches newest to oldest (`search/screen.zig`, `Select.next`), so `next`
moves **up** the screen and the nearest occurrence that way is the one it selected. Nothing
that way means it had to scroll to reach the match, and a scroll parks the match's own row
at the viewport top (`search/Thread.zig` scrolls to `flattened.startPin()` only when no
viewport chunk already overlaps), so the topmost occurrence is the answer. Case folding is
ASCII-only, matching the engine's `std.ascii.indexOfIgnoreCase`.

**A needle is one line, and that is the chrome's limit rather than the engine's.**
libghostty writes a `\n` between rows that are not soft-wrapped
(`search/sliding_window.zig`), so it would match across a break. Everything downstream
here is per-row though: the scan, the cursor and the landing. Keeping a multi-line needle
was tried and reverted, because it produced a count and highlights for matches nothing
could navigate to, which reads as the mode being broken rather than as a limit. A
selection dragged across rows is cut to its first line, and the field then shows exactly
what will be searched, which is the whole of how a reader sees it happened.

That is inference, and it can pick the wrong occurrence when one screen holds several. It
is worth it here only because **the failure is visible**: libghostty is painting the match
it selected at the same time, so a disagreement is two markers on one screen and one `j`
fixes it. A soft-wrapped match is not found by a per-row scan and the cursor stays put.
Do not try to close this by tracking viewport offsets or forcing a scroll before every
navigate; both were considered and neither makes the answer knowable.

The four `search-*` colors are emitted from `Theme.current` by `AppTheme`'s init, so a
terminal theme cannot reach a surface without them (ZEN-91). Candidates sit back toward the
terminal background so a screenful of them is not a wall; the selected one takes the accent
at full strength and inverts its text. A theme file naming its own keeps them.

`TerminalSurface.text(in:)` is the yank's read and the deliberate opposite of
`text(viewportRow:)`: it *wants* `read_text`'s unwrapping, so a command line that soft-wrapped
over three rows reaches the pasteboard as the one line it was typed as.

Below the seam each command is one `ghostty_surface_binding_action` string, and the
signs match (`TerminalScroll.lines(1)` is down, as `scroll_page_lines:1` is).
`GHOSTTY_ACTION_SCROLLBAR` feeds `scrollPositionDidChange` back up, which is what
puts a live count in the pane header. It fires on output too, so the count stays
right while a pane keeps printing.

**The retractions are the load-bearing half.** The mode holds an app-global key
handler, so one left up deafens whatever you switched to. It ends when pane focus
moves (which covers pane close, split and tab switch, since all of them route
through `restoreUnifiedFocus`), when a tool float or modal card takes the keyboard
(neither moves pane focus, so neither fires the focus relay), and when the window
resigns key. `end()` is idempotent, so overlapping triggers are free.

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
surface, and rebuilt the toolbar each time (~3.4 ms a post). Gated, a keybind rebind
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
the toolbar rebuild and the tab relayout, not shaving a keycap rebuild.

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
- **No tab drag-to-reorder**, no config file watcher.
- **Two seam events are emitted with zero consumers**: `surfaceDidRingBell` and
  `progressDidChange`. The backend translates both, but nothing in the chrome
  implements them. Pane exit runs entirely through `surfaceDidExit`.
