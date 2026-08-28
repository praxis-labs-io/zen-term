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
not for a size the user is holding a key to change. It takes an absolute
size, never a delta, so the chrome stays the single owner of the number: a stepping
API would leave the running size inside each surface where the chrome can't read it
back, and surfaces would drift apart at whatever bounds the backend enforces.

Four types travel with it: `TerminalSurfaceConfig` (spawn params),
`TerminalSurfaceDelegate` (seventeen events out, all defaulted to no-ops),
`TerminalTheme`, and `TerminalBehavior`.

**`disposition(of:)` asks the backend what it would do with a keystroke.** The
chrome resolves its keymap before the responder chain and passes on everything it
does not claim, so the backend's own keymap is live underneath ours the whole time.
This is how the chrome finds out what is down there, rather than reading it out of
the backend's source. Both its callers ask about a chord nobody pressed, so it
takes a `TerminalKey` (keyCode, modifiers, unshifted codepoint, typed text) rather
than an `NSEvent`: fabricating an event is the trap in `swift-conventions.md`.
Defaulted to `.ignores`, so a backend with no keymap needs no code.

Both spellings of the key travel because libghostty tries both. `Binding.Set.getEvent`
looks up the physical key, then the typed text, then the unshifted codepoint, so a
bind written `cmd+shift+|` is reachable only through the text and one written
`cmd+shift+\` only through the codepoint. Sending one of the two would leave the
sweep blind to half the keymap, which is the one thing it exists not to be.

`ChordDisposition` has four cases and the fourth is the one that matters.
`mayClaim` means the bind is conditional: the backend runs it only when the action
would do something and otherwise lets the key through. libghostty's
`keyEventIsBinding` is a pure set lookup that does **not** evaluate that, which its
own doc comment says outright, so a probe cannot resolve it and must not round it up
to `claims`. `clear_screen` is the proof: it reaches vim, because vim runs on the
alternate screen where clearing does nothing, and on the primary screen it claims
whether or not there is anything to clear. So the condition is the screen it is on
rather than the work being done. The `⇧`-arrow selection binds are the same shape, on
whether a selection exists, and they are still in the shadow for the sweep to meet.

**ZenTerm unbinds most of libghostty's keymap, and `GhosttyUnboundChords` holds the
decision.** A bind is taken back when ZenTerm already has an action for it,
so the backend's copy only duplicates the chrome in ghostty's vocabulary, or when its
action reaches an apprt callback we never implement, so the key is swallowed and
nothing happens. `GhosttyConfigWriter` emits one `keybind = <trigger>=unbind` line
per chord, which is the only channel there is: libghostty takes configuration from
files and has no setter API.

What survives is `GhosttyUnboundChords.kept`, and it is one thing:
terminal encoding rather than chrome action. `⌘←`/`⌘→` send `^A`/`^E`, `⌥←`/`⌥→` send
`ESC b`/`ESC f`, `⇧`-arrows adjust a selection. A keystroke that turns into bytes for
the program is not a shortcut, and those stay with the backend for good, so the list
is finished rather than waiting on the next ticket.

The behavior ZenTerm had not named yet is now named. Seven of them rode
seam methods the protocol already had, and the last seven grew the seam
for them: `clearScreen`, `selectAll` and `writeScreenToFile` on `TerminalSurface`, and
`.selection` and `.prompt(Int)` on `TerminalScroll`, since scrolling to a selection and
jumping a prompt are viewport moves and the sign convention already covers them.
Paste-the-selection needed nothing new, and could not have used what ghostty means by
it: `paste_from_selection` reads the X11 selection clipboard, which macOS has none of,
so with `supports_selection_clipboard` off it pasted what ⌘V pastes. The chrome reads
the selection you can see, from both selection models, and pastes that.

`BackendShadowSweepTests` walks the whole typeable chord space against a live surface
and fails unless the surviving shadow is exactly `kept`. It replaced a baseline that
pinned only the chords under our own defaults, which could not see an unbind that
stopped matching. Re-run it on a ghostty pin bump: a change there is not
automatically a bug, but it must never be silent.

**`BackendShadow` is the same question asked at load time, and it is the half a
build-time test cannot reach.** A user keybind moves its action, `KeymapAssembler`
drops that action's defaults, and the freed chord goes to the backend, which no
build-time test can see because on a default install the chord is still ours. The
shadow surface is a function of the user's config, not a constant. `AppDelegate` runs
the report once the first window has a surface to ask through, and `ConfigApplier`
re-runs it whenever the keymap changes, because the backend answers against its
config as it stands now. It logs and shows nothing: the probe answers a disposition,
not an action name, so a line can say the backend takes a chord but not what it does
with it.

**It finds nothing today, on any config.** Rebinding nav to `ctrl+hjkl` used
to make ⌘K clear the scrollback; naming `clear_screen` and unbinding libghostty's copy
was the last chord a ZenTerm default could hand back, and what survives down there is
encoding no default sits on. The check stays as a regression guard: a pin bump that
binds something under one of our defaults is invisible otherwise.

It confirms the backend is answering before trusting an empty result, on ⌥←. A
`TerminalSurface` exists before its backend surface does (`ghostty_surface_new` fails
on a locked screen and leaves the object alive), and every chord then reads
`.ignores`. Without the check, a dead probe and a clean config are the same answer,
and an empty result is this check's all-clear. **The canary has to come from the
permanently-kept set:** it was ⌘T until that chord was unbound, and a canary we later
unbind reports a dead backend forever without changing anything else.

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
                     depend on it for diagnostic logging
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
  cursor shader stands down on an unfocused pane. Theming stays global:
  the per-surface shape is rebuilt from the theme that just landed, so a stood-down
  surface follows an appearance change instead of holding the old one.
- **libghostty accepts config only from files.** `GhosttyConfigWriter` writes to
  `$TMPDIR/zenterm-ghostty-config-<pid>`. It deliberately does *not* call
  `ghostty_config_load_default_files`, so a user's `~/.config/ghostty` cannot skew
  ZenTerm's appearance. Because that means a synchronous write, read and parse on
  the main thread, the per-surface configs are cached by their generated text and
  cleared when the app-global config moves.
- **A per-surface config push must carry that surface's font size.** `Surface.updateConfig`
  resets the size of any surface libghostty has not marked `font_size_adjusted` to
  whatever the pushed config says, so a push built from the theme alone silently
  drops a pane's stepped size. `updateSurfaceConfig` takes a `fontSize` for this;
  the app-global config leaves it nil, where the theme's size is correct by
  definition.
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
  place per-surface state is real.

  **Re-check this on a ghostty pin bump** by diffing `ghostty +show-config` with and
  without the `theme` line. Every resolved key should be byte-identical apart from
  `window-theme`; anything else moving means the explicit colors have stopped
  outranking the loaded files. That diff is what caught the `window-theme` move.
- **Shader draw stops when nobody can see it.** The focus libghostty is told about
  is `paneFocused && isAppActive`, and `GhosttyHostView` reports its window's
  occlusion, so a backgrounded, covered or minimized window runs no shader draw
  timer at all.
- **Teardown sweeps process sessions, not process groups.** libghostty sends
  `SIGHUP` to the shell's own process group, which misses every job the shell
  parked elsewhere: background jobs, children in their own process group (what
  `npm`, `turbo` and watchers do), `nohup`, `disown`. Those survived a closed tab
  and a quit. `ShellSessionLedger` records every shell session the app
  starts; teardown sweeps the ones whose *leader has exited*, via
  `ShellSessionReaper` (`SIGTERM`, 150ms grace, `SIGKILL`, off-main).
  **Each leader is watched for its own exit**, with a kqueue process source armed
  when it is recorded. It used to be polled for inside a one-second window, which
  meant a leader slower than that was never swept at all: nothing rescheduled a
  look, so on the last pane its dev server outlived the close. No
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
.
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
  past left and right were missing for exactly that reason: the app looks
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
  over it.

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
(`LinkPreviewPresenter`), so underline, pointer cursor and URL preview
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
whole of `background-alpha`, and nothing else. An earlier version carved out an
exception dropping the layer out of opaque whenever a shader was on, against an
alt-screen white flash; it was removed, because that flash was root-caused by
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

**The window-level stack, back to front: canvas, tool float, tab bar and dock, toast
stack, modal card.** Each position is a decision, not an accident. A **float** sits
below the tab bar because the ⌘W guard toast ("Close btop first, then ⌘W") fires
while a float is open and is telling you to close that float, so the toast has to
win. A **modal card** is the opposite case: it owns the keyboard and dims the tile,
so a passive notice over it reads as broken, and it mounts at the front.
Two things follow. The toast stack is built lazily on the window's first toast, so it
inserts *below* a card that is already open. And a card is window-hosted, so nothing
unmounts it implicitly: the `closeModal()` in `select` / `addTab` / `closeTab` is what
keeps a card from outliving the tab it was opened over, and it owns its own gutter
constraints (`reapplyModalLayout`) rather than inheriting the tile's.

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
| Tool floats | `ToolFloatController` | per window (Scratch: per tab) |
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
adds/drops the traffic-light clearance to match. **Fill Screen** (⌘⏎) toggles the
window between its size and the screen's visible frame; it is a maximize, not native
fullscreen (no space switch, the menu bar stays).

**Modal cards share one slot.** `ModalKind` plus a single `modal` property. A chord
for a different card closes the current one and falls through, so cards switch
live.

**Tool floats are window-level, not app-level**, because a surface is one `NSView`
and can live in one view hierarchy: an app-global instance would physically yank
the float out of window A when opened in window B. `ToolFloatController` holds no
reference to any `TabController` and reaches the active tab through injected
closures. Liveness and visibility are independent: `activeFloat` is the one shown,
`liveFloats` are the ones alive.

**The card is always the window's; the instance follows `ToolFloat.Scope`.** A
`.window` float has one instance shared by every tab. A `.tab` float has one per
tab, filed in `liveFloats` under `tabID/id` instead of the bare id, and terminated
by `shutdownScope` from `closeTab` and `replaceActiveTab` beside
`TabController.shutdown()`. Scratch is the only `.tab` float, and the axis is
deliberately unparseable: it is not a `persist:` case, because
`Persistence(rawValue:)` *is* the config parser, and `persist:tab` was cut after
daily driving showed tab scoping is the wrong axis for a tool.

**Every silent no-op is a toast.** Focus-Mode-blocked commands, dead nav directions,
git-guarded floats, ⌘W over a float. Both toast paths throttle at 3s per verb
because held chords auto-repeat.

**A surface that states current state needs a retraction written with the raise.**
A sticky toast, badge, or banner says what is wrong *now*, so fixing the cause has
to take it down; a warning that outlives its cause costs the same trust as a dead
control. When a command is gated off in some build configuration, make the off
state say so. Inert is fine, silent is not.

**A toast's keys live on the card root, never on a button.** A confirm claims Return,
Delete and Esc in `ToastView.performKeyEquivalent` *and* `keyDown`, matched by keyCode
through `KeyboardFocus`. Both entry points, because neither covers the other: AppKit
skips the traversal for a bare key while some focused hosts hold it, and `keyDown` only
arrives while the card holds first responder. Space is refused on purpose, though
`KeyboardFocus.key(for:)` folds it into the same `.activate` as Return: a confirm's
affirmative quits the app. A non-modal sticky card claims none of them, so the terminal
under it keeps every key; `dismiss_toast` and `dismiss_all_toasts` are how those come
down from the keyboard, and both run the card's own cancel action so a tab's attention
marker clears with it.

Whether the two notification cards wait or clear themselves is `attention-toast` and
`completion-toast`; `toast-duration` is how long anything that clears itself stays up.
The presenter holds the duration as a `var` re-pointed by `reapplyDuration`, because it
is built lazily on a window's first toast and would otherwise bake the value for the
life of the window.

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
- **Keyboard-driven lists scroll themselves as the selection moves**, through
  `KeyboardFocus.reveal(_:among:)`: the Settings detail sections, the command palette,
  and the repo picker all call it, so they behave identically. AppKit does not scroll
  to a newly focused responder, so it computes one position per keystroke and applies
  it. It covers the strip between the previous stop and the destination, not just the
  destination, or a group caption or section header (and the document's top inset)
  parks off the top edge. It also aims past the edge the stop arrives at by a margin,
  so a row never lands flush against the pane edge. The margin goes on the **arriving
  edge only**: padding a rect on both sides and handing it to `scrollToVisible` lets
  the far edge pull the near one around, which moves the list while the selection is
  still mid-pane. **Do not animate this.** An eased scroll was tried and reverted: a held arrow repeats faster
  than any ease settles, so closing the gap fast enough to keep up moves the text tens
  of points per frame, which reads as doubled or blurred glyphs. Pixel-snapping the
  offset and disabling the clip view's copy-on-scroll blit made no difference, because
  the artifact is the per-frame distance, not how the frame is drawn.

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
placement is the design: a mode installed above it would swallow ⌘T, ⌘⇧P and pane
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
`NSApp.sendEvent` resolves menu key equivalents, and ⌘C/⌘V/⌘A/⌘Q are menu items rather
than reserved chords. A mode that consumed every unmapped key killed Copy and Quit
for as long as it was up. A mode consumes an unmapped key only when it carries no
⌘ or ⌥, which is exactly the set that would otherwise reach the shell as input.

**Past the monitor, AppKit still claims keys before `keyDown` runs**, so
`GhosttyHostView.performKeyEquivalent` takes the ones a pane needs back: Ctrl-Return, which the
default context-menu equivalent would eat, and Ctrl-/, which macOS routes to the first view in the
hierarchy and beeps at (rewritten to Ctrl-_). Every other ⌘ or ⌃ key is declined once and its
timestamp recorded, so a menu item still wins the first pass; `doCommand`'s redispatch is what
sends one back to be claimed on the second. Ported from ghostty, minus its binding branch, which
`KeyInterceptor` already covers. The failure modes are in `docs/swift-conventions.md`.

**`Chord` canonicalization** is the sharpest rule in the codebase. A shifted glyph
folds onto its base key **only when Shift is set**, because
`charactersIgnoringModifiers` applies Shift: a live ⌘⇧- arrives as `_` while the
config spells `cmd+shift+-`. The Shift gate is load-bearing, not a formality: the
fold table is US-only, and `_` is unshifted on AZERTY. Folding on glyph alone would
give a keypress a Shift its user never held. **A non-US layout can at worst
mislabel a chord, never invent one.**

**A key that types no character is a glyph in the app and a word in the file.** The
arrows, Return, Tab, Home, End and the page keys carry a character no fold
table knows, so `Chord` names them by keyCode (`specialKeyGlyphs`) and everything
inside the app matches on `↖`. A config cannot: nobody types ↖ into a text editor. So
`parse` reads `home` and `configToken` writes it back, and the screen still draws the
glyph. `KeyboardLayout.resolve` consults the keyCode table **before** the character
walk, which is what keeps `canType` from calling these untypeable and dropping a
rebind onto one.

Defaults (`KeymapDefaults.map`): ⌘D and ⌘⇧D split, ⌘⌥arrows nav, ⌘⌃arrows resize, ⌘W
close pane, ⌘T new tab, ⌘N new window, ⌘[ ⌘] tabs, ⌘1-9 select, ⌘B bottom drawer,
⌘\ right drawer, ⌘⇧⏎ Focus Mode, ⌘⏎ Fill Screen, ⌘⇧S scroll mode, ⌘F find, ⌘⇧P command
palette, ⌘P workspace picker, ⌘, settings, ⌘⇧, reload, ⌘= and ⌘+ and
⌘- font size, ⌘0 reset it. Five more sit on the chords libghostty already used
for them: ⌘Home, ⌘End, ⌘PageUp, ⌘PageDown scroll the viewport and ⌘E finds the selection.
Then ⌘K clear screen, ⌘J scroll to the selection, ⌘⇧J and its
⌃/⌥ variants write the screen to a file, ⌘⇧V paste the selection, and the prompt jumps on
⌘⇧↑ and ⌘⇧↓. Select All is ⌘A and is the Edit menu's rather than the keymap's, for the
reason below.
**One tool float is built in**, Scratch on ⌘;, and its chord is a default here like any
other action's. Every other float's chord comes from its own `key:` field.

**The defaults are ghostty's, and the premise is that a chord doing the wrong thing costs
more than a chord doing nothing.** So where the two disagree, the concession goes to what a
ghostty user reaches for first: the splits hold ⌘D and ⌘⇧D (the most-pressed chord in a
ghostty split workflow after ⌘T), pane focus and resize hold ⌘⌥arrows and ⌘⌃arrows, ⌘F is
Find, Focus Mode and Fill Screen sit on ⌘⇧⏎ and ⌘⏎, and the palette holds ⌘⇧P with the
workspace picker on ⌘P.

**One chord per action.** A second spelling costs a Shortcuts row that has to pick one of
the two to advertise, a line in the reference config nobody asked for, and a rebind that
has to free both. `KeymapAssemblyTests` holds the rule as an invariant, with increase font
size named as the one exception (⌘+ *is* ⌘⇧= on a US layout, so the pair is one chord
spelled two ways).

Ghostty is the outlier on ⌘[ / ⌘], which it spends on panes; ZenTerm holds them on tabs,
which is Safari's assignment. That is the one place a ghostty hand lands on the wrong
action rather than on nothing, and it costs one keystroke to undo. `Chord` parses `tab`, so
a config binding ghostty's ⌃⇥ resolves even though no default holds it, and Tab is the one
entry in `Chord.specialKeyGlyphs` that types a real character: `\t` draws as nothing on a
keycap and reads as a stray blank in a config file.

**macOS takes some chords before any app sees them, and a chord bound there is dead while
every test of it passes.** ⌘⌥D is the Dock toggle and ⌃⌘D is Look Up, so nothing may reach
for a spare D. The keymap is an event monitor, so there is nothing to catch this below
the machine: it takes a person pressing the key. ⌃⌘F is not this case. It is ghostty's
second spelling of fullscreen and stays unbound because it is macOS's *native* fullscreen
chord, and Fill Screen is a maximize, so answering it would promise a space switch it does
not do.

**Pane cycling is ⌘⇧[ / ⌘⇧]**, which ZenTerm had no action for at all: nav was directional
only. `TabController.cyclePane` steps the pane tree's leaves and then whichever drawers are
open, wrapping at both ends. The drawers are in the ring on purpose: leaving them out would
let focus cycle out of a drawer and never back in. The step is deliberately not geometric,
so it stays predictable in a layout where "next" has no direction, and one panel is a
silent no-op the way `cycleTab` is for one tab. ghostty spends this pair on tab cycling,
which is the second half of the bracket divergence above.

**⌃hjkl is deliberately not the default nav**, though it is the obvious vim habit. It costs
⌃L clear-screen and ⌃K kill-line in every plain shell pane, and neither is worth a
directional chord ⌘⌥arrows already covers. The reference config carries it as a four-line
recipe.

**The screen actions are on libghostty's own chords**: Clear Screen ⌘K,
Scroll to Selection ⌘J, Write Screen to File ⌘⇧J. Writing the screen has three endings and
the backend takes the choice in with the call, because it disposes of the path inside the
same action and never hands it back: ⌘⇧J types the path into the pane, ⌘⇧⌃J copies it,
⌘⇧⌥J opens the file. (Select All holds no keymap chord because Edit > Select All carries ⌘A,
per the rule below. Check for Updates and Report an Issue hold none either: Report an Issue is
in the Help menu, and Check for Updates is reachable only from the palette or a rebind.)

**A verb a text field owns is served from the Edit menu, never from the keymap.** Select All
is the case that set the rule. `KeyInterceptor` resolves ahead of the responder chain, so a
keymap default on ⌘A takes the chord from every field in the app: the palette filter, a
Settings field, the find bar, the Report an Issue composer. Edit > Select All carries ⌘A
instead, with AppKit's own `selectAll:` and no target, so the chain decides. A focused field
editor implements it and takes it first; `WindowController` implements it as the terminal
endpoint below, and swallows it over a modal card, which has no buffer to act on. Copy and
Paste are the same three lines for the same reason: they carried a custom `copyFromSurface:`
selector that walked past the field, so ⌘C in the find bar copied the buffer behind you while
you typed. Cut, Undo and Redo are in the same menu for the same reason and stop at the field:
macOS ships no default key binding for them, so an app with no items has ⌘X and ⌘Z dead in every
box it draws, and a bare `NSTextView` needs `allowsUndo` set or Undo greys out where people
write paragraphs.

`select_all` stays an action a config line can bind to some other chord, and it is in neither
the palette nor the Shortcuts card, the same as Copy and Paste: the menu is where ⌘A is
offered, and a second listing would advertise a chord the Shortcuts card has to refuse. Two
costs come with that, and the reference config states both. Every bind landing on ⌘A is now
refused, not just `select_all`, so a config that had `clear_screen=cmd+a` loses it on upgrade.
And `select_all=none` no longer hands ⌘A to the program in the pane, because a key equivalent
is not the keymap's to unbind.

**A responder that keeps its own selection has to answer `selectAll:` itself.** `NSTableView`
implements the selector, so a nil-target menu item reaches a table ahead of the window. A view
that tracks its own cursor and anchor must route `selectAll(_:)` out to that model rather than
calling `super`, or the table lights every row while the model still points at one.

Stepping a search is `n` and `N` while the search holds the keyboard, so `search_next` and
`search_previous` ship with no chord and `SearchController.key(for:)` reads them. They stay
rebindable, and they stay out of the palette: opening it tears the find bar down, which
would make the row a no-op every time.

**Which chords a text view owns is a measured fact, not a guessed one.** ⌘⇧↑/⌘⇧↓ are
`NSTextView`'s own bindings (extend selection to start and end of document) and ⌘A is
not, which is the whole difference between the two cases above and is invisible from
reading. `TextEditingChords` holds the set, `AppDelegate` consults it through the same
`passThroughGuard` seam `NavGuard` returns through, and `TextEditingChordsTests` sends
the keystroke to a real text view and reads its selection back rather than asserting on
the predicate. A guard that answers "yes, defer" for a chord nothing downstream
implements hands the keystroke to nobody, which looks identical to working.

**⌘⏎ and ⌘⇧⏎ are in the same set for a different reason.** Not because macOS binds them,
but because AppKit turns every Return into `insertNewline(_:)` whatever modifiers ride along,
so a composer that tells send from new line reads them off the raw event. Fill Screen and Focus
Mode sitting on those two chords is right for a window and wrong for a caret. The test routes
the event through `KeyInterceptor` and asserts the same event comes back, because the guard
returning `true` proves nothing about whether what survived is still readable.

**Increase ships two chords, and the second is load-bearing.** ⌘+ on a US layout is
physically ⌘⇧=, which `Chord` folds onto `=` because Shift is set, making it a
different dictionary key from bare ⌘=. Bind only ⌘= and the keypress most people make falls
through to libghostty, which still has it bound per surface, reproducing that bug
for the common case. It is the one action with two defaults; `assemble` drops all of
an action's defaults on a rebind, and `Chord.displayed` sorts by config token, so a
keycap renders the plainer ⌘=. (An earlier keymap moved split off bare ⌘- to leave it to
libghostty; the chord came back, and it is font size alone now.)

**The prompt jumps are the mirror, and the same sort rule is why.** libghostty binds
them on bare ⌘↑/⌘↓ *and* ⌘⇧↑/⌘⇧↓; ZenTerm ships only the shifted pair, which is the one
place we bind fewer chords than the backend did. macOS claims the bare pair on a stock
Mac, so the keypress never arrives, and a second default nobody can press is not free:
`cmd+down` sorts under `cmd+shift+down`, so the keycap for Jump to Next Prompt would
have advertised the dead spelling while Jump to Previous Prompt advertised the live one.
Two rows disagreeing about their own shortcut is worse than one chord fewer. Found at
the machine, not by a test, which is what the runbook is for.

`KeymapAssembler.assemble` resolves defaults, then float chords, then user
keybinds, later winning. **A user keybind moves its action**: the action's default
chords are dropped first, so the old key is freed rather than both firing.

**Unbound is a value, not an absence.** `keybind = search_next=none` drops
the action's defaults and puts nothing back, so the chord reaches the program. The
drop happens in the same filter a rebind uses, ahead of every write, and that is the
whole mechanism behind an unbind being silent: the chord is free by the time a float
claims it, so no displacement is recorded and there is nothing to report.

The reason it cannot be inferred from the keymap is the writer.
`ConfigWriter.apply(keybinds:)` regenerates the entire `keybind =` block from what
it is handed, and an action holding no chord is missing from a `[Chord: Action]` map
exactly the way an action sitting at its defaults is. So `KeymapOverrides` carries
`binds` and `unbound` side by side, `assemble` returns the second, and
`GeneralConfig.unboundActions` holds it. Without that, the next Settings write
deletes the line the user wrote.

**A chord conflict carries its own answer, so it gets a card of its own.**
`KeybindConflict` reads them off the `.chordTaken` diagnostics, and
`ConfigApplier.surfaceConflicts` raises one sticky card each while everything else
keeps sharing the one notice (`ConfigDiagnostic.isChordConflict` is the split, and it
sits ahead of the empty check so a conflicts-only set still retracts a stale shared
notice). One card per conflict rather than a list: each is a separate decision, and
aggregating three would let one dismissal settle all of them.

Both answers are edits to the config, because the config is what created the
conflict, and both go through `KeymapOverrides` alone. **Accept** writes `= none` for
the action that lost the chord. **Revert** puts the winner back on its defaults,
which makes its line equal to the defaults so `ConfigWriter`'s per-action diff stops
emitting it; the chord then returns to the loser because no line names the loser and
the assembler hands every unmentioned action its defaults. Reverting a line is not a
special delete, it is the writer declining to write what it no longer needs to.

**A float gets Accept alone.** Its chord is the `key:` on its own `float =` line and
`key:` is required, so there is nothing to back out to. `isRevertable` is what both
surfaces read to decide whether the button exists at all.

Re-carding is gated on the conflict set changing, because every in-app write reloads
and a Settings keystroke would otherwise restore a card the user just closed. A
launch is a fresh process, which is what makes an unanswered conflict come back. The
card arms no key equivalents, so Esc keeps reaching the pane and the × is
the only keyboard-free way out.

**Delete removes; reset is an icon beside the input.** On a `KeybindChip`, Backspace
leaves the action with no shortcut and writes `= none`. It used to restore the
default, which read as doing nothing on exactly the rows most likely to be pressed:
an action whose default is a chord something else already holds gets it back and
loses it again on the reload. Reset moved into the capture popover, next to the input
it acts on, hidden on a row already at its defaults and on one whose chord a float
took, where binding back to the defaults leaves the chord set unchanged so the writer
emits nothing and the icon would do nothing. A refused chord returns the input to its
listening placeholder rather than sitting in it, since the box is where a *recorded*
chord appears.

**Settings sets shortcuts; the card answers conflicts.** A conflicted row shows its
chip and a muted line naming the config line that has the chord, and offers nothing
else. Accept and Revert lived on the row briefly and came off: a forty-row list where
a handful of rows sprout a button pair has no stable rhythm, and the pair competes
with the chip for the same job in whichever column it is put. Dismissing a card means
"not now", and it returns next launch carrying the same answers, so there is no state
needing a second path here.

**The modal gate cascade** in `WindowController.handle(_:)` runs confirm, then
modal card, then tool float, then dispatch. The app-global chords (⌘N new window,
⌘⇧, reload config, the three font-size chords, and the unbound-by-default Check for
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
answer by walking away.

**The float stage speaks rather than swallowing.** A pane command (nav, split,
resize, drawer, Focus Mode) pressed over an open float has nowhere to go, so it
raises a notice naming the float instead of doing nothing at all. The reading
chords do have somewhere to go and pass straight through: scroll mode, find, the
scroll and prompt-jump chords, clear screen and the screen-to-file verbs all act on
the card's own buffer, because `modeTarget` resolves the shown float first. Held
chords auto-repeat, so it coalesces on a 3-second throttle, the same shape as the
zoom-block and no-neighbor toasts. It is not keyed by chord: the notice reads the
same whichever was pressed, so a second chord inside the window would only repeat a
card already on screen.

**The nav socket** backs [zen-navigator.nvim](https://github.com/praxis-labs-io/zen-navigator.nvim).
`NavSocketServer` listens on `~/Library/Application Support/ZenTerm/nav.<pid>.sock`
and exports it as `$ZEN_SOCK`. **Per-pid, not a well-known path**: a shared path let
a dev build bind over the installed app's socket and delete it on quit, leaving
every nvim deaf until relaunch. Failure is silent and non-fatal, because ⌘-nav never
depends on it. The wire contract is `docs/nvim-navigator-protocol.md`.
`NavGuard.shouldPassThrough` passes through only Ctrl-nav, never ⌘-nav, so default
pane nav is untouched whether or not the pane runs nvim.

**The theme state file** backs [zen-theme.nvim](https://github.com/praxis-labs-io/zen-theme.nvim).
`ThemePublisher` writes `~/Library/Application Support/ZenTerm/theme.json` at launch
and on every `.theme` change, so an editor recolors with the chrome. **A fixed path,
not per-pid and not exported in the environment**: a float launches with no
environment, so a reader inside one could never be handed a path. Two instances are
last-writer-wins, which a theme change corrects. Each bundled theme names its Neovim
colorscheme in an `nvim-colorscheme` key that `GhosttyThemeParser` drops as unknown,
so the mapping ships in the theme file and a user's own theme takes one line. The
wire contract is `docs/nvim-theme-protocol.md`.

Two things claim a Ctrl-nav chord ahead of pane nav: a pane running nvim, and **an
open tool float**, whatever it is running. A float is modal, so `handle` swallows nav
while one is up; consuming the chord took it from the tool and then dropped it, which
is how Ctrl-hjkl died inside an nvim float. The float path needs no vim
check and no socket at all. A float mints no nav token and gets no `$ZEN_PANE`, so the
plugin inside one degrades to plain `wincmd`, which is the right behavior for a modal
surface with nowhere to hand off to.

### Scroll mode

⌘⇧S reads back through the focused panel's scrollback from the keyboard.
`ScrollModeController` owns it, one per window, and it targets whichever panel held
unified focus when it opened. It does not follow focus afterward.

**Its target is a `TerminalModeHost`, not a pane.** A shown tool float is modal over the
panes behind it, so `WindowController.modeTarget` resolves the card ahead of the focused
panel and every reading chord acts on the terminal you are looking at.
`PanelHostView` and `SurfaceFloatOverlay` both answer the protocol, and `ModeChrome`
holds the three strips a mode hangs off them: the header, the find bar and the cursor. A
float wears no header at rest and grows one only while a mode is up.

**It exists because the keys that should scroll a buffer are the shell's.** `j`,
`k`, `⌃d` and `⌃u` cannot be reserved chords without taking them from every program
in every pane, and libghostty's own ⌘Home/⌘PageUp defaults (live in ZenTerm, since
the chrome never claims those chords) are fn-chords on a laptop that nothing in the
UI mentions. A mode borrows the keys while it is up and gives them back on exit.

**The keymap is its own file.** `ScrollKeymap.key(for:pending:hasSelection:)` is a pure
static over `NSEvent`, and it
reads shiftedness from the modifier flags rather than character case for the same Caps
Lock reason. j/k step the cursor, h/l move a column, w/b/e and W/B/E move by word and
WORD, 0/^/$ reach the ends of a row, H/M/L name a row by where it sits, f/F/t/T find a
character with ;/, repeating it, ⌃d/⌃u move a half page, ⌃f/⌃b and space a page, gg/G the
ends, { and } move by paragraph, v/V select, y copies and yy takes rows, * searches the
word under the band, and Esc/q/i leave. **Every key is consumed, mapped or not**: passing misses through would drop a stray
keystroke into the shell behind the mode, which is worse than one that does nothing.

**Counts and two-key commands come in as `Pending`, not off the controller**, so the
decode stays a function of its arguments. A digit is not a move, so it comes back as
`Key.count` rather than a `Command`, which keeps the run switch exhaustive with no
unreachable branch. `0` is `lineStart` until a count is being typed and a digit after
that, which is vim's own rule: without it `10j` is a column jump and one step. The count
survives an arming key, since the `2` of `2yy` is typed before the first `y`.

Three things the count does that are worth knowing. It folds into the command where the
command carries a magnitude, so `12j` is one `.step(12)` rather than twelve of anything.
It scales a page rather than repeating it. And stepping past an edge moves the cursor as
far as it goes and scrolls the remainder, so `15k` eleven rows down moves eleven and
scrolls four rather than scrolling all fifteen.

`{`/`}` are the exception, and deliberately: the count repeats the motion rather than
folding in, because `paragraphRow` uses the delta as its row-by-row stride and a folded
count would step the scan over the blank lines it is looking for.

`G` takes no count, and cannot: `Point.pin` clamps every coordinate to the grid, so no
number names a scrollback line for `30G` to reach. `H`/`M`/`L` reckon from the last
**written** row instead of the grid's bottom, which on a half-filled screen is empty space
below the prompt.

**A page move advances the cursor and the viewport follows.** `⌃d` moves the band half a
screen through the buffer; the viewport takes as much of that as it can, so the band parks
at the middle of the screen while the text runs under it; and where the viewport cannot
take it all, the cursor makes the rest of the trip. That last clause is the only way to
reach the last half page of a buffer by paging, since a page that only moved the viewport
stopped dead at the end with the band still mid-screen.

The distance is worked out here and sent as **rows**, not as a fraction, so the mode knows
where the band lands rather than finding out from the next report. `linesBelow` and
`offset` say how far the buffer can still go, which is what makes the split between the
two exact.

**The cursor is the chrome's, drawn on the pane.** libghostty has no copy mode and no
cursor outside the shell's own, so `ScrollCursorView` paints the band on the current row,
a stroked cell where the cursor is, the selection rects, and the yank pulse, added by
`ModeChrome` inside the host's card and pinned to the terminal view rather than to the
card, so its row math is in the surface's own coordinates. It returns nil from `hitTest`, because
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

**Live output does not move the screen out from under the band.** libghostty's viewport
follows the active area only while it rests at the live end, so a `tail -f` under an open
mode scrolls away the line being read. A report whose buffer grew by exactly as many rows
as the viewport moved is that push: a scroll the reader asked for leaves the buffer's size
alone. The mode pulls the viewport back by that many rows. One pull is the whole fix,
because above the active area libghostty pins the viewport itself and output accumulates
below, which is what the header's growing count then reads.

**A rewrap has the same signature**, and this is the trap. Narrowing a pane pushes rows into
the buffer and, resting at the bottom, moves the viewport by exactly as many. `refreshGeometry`
arms a stamp that suppresses the hold until the report answering the reflow arrives, bounded
like `pendingAnchor` and for the same reason. It cannot key off `pendingAnchor` itself, which
is nil whenever the band has no line to re-find, which is every page move.

Leaving hands the live end back, but only what the mode took: a report that moves the viewport
without the hold behind it is the reader or the find bar choosing a place, and that place
survives `q`. A reader who entered already scrolled back never held anything.

**At the scrollback cap the band drifts as it did before.** ghostty trims from the top rather
than growing, so `total` and `offset` both stand still, the report is identical to the last one
and is therefore never emitted, and no signal reaches the chrome at all. Nothing at the seam can
see it.

It cannot pin on entry instead. `PageList.scroll` turns any pin inside the active area
back into a follow, so the only way to be pinned is to sit a row above the end, and moving
the screen on entry is the one thing the mode promises not to do.

**The mode opens on a mouse selection when there is one**, on its first cell, so a reader
who selected something and then reached for the keyboard keeps their place. `ghostty_text_s`
carries the selection's top-left in view points, which divides straight down into a cell.
Only the near end: no backend here reports where a selection finishes.

**With nothing selected it opens on the last written row of the viewport**, found by
reading rows from the bottom up. Not the bottom of the pane, which on a half-filled screen
is empty space below everything there is to read, and not the shell's cursor:
`ghostty_surface_ime_point` reports that against the *live* screen with no account of
scrolling, so a viewport already scrolled with the wheel put the band on an unrelated row.

**The entry row is read before the header goes up, and remembered by its text.** A pane's
header is hidden until a mode shows it, and showing it moves the content's top constraint
down by its height: the terminal loses a row or two, reflows, and the pty gets a SIGWINCH.
A shell redrawing a multi-line prompt **clears those rows first**, so a read taken after
the header finds them blank, and the walk-up skips the prompt and stops on the last line
of the previous command's output. Reading first is the only moment the prompt is
guaranteed painted.

The row index does not survive that resize, so it is not what is kept. The line's text is,
and `refreshGeometry` runs nested inside the layout to arm it: the first scroll report
after puts the band back on that line wherever the shell repainted it. This is the same
machinery a font step and a divider drag use, pointed at entry.

**A move that names a destination puts the cursor on it**, rather than bringing it into
view and leaving the cursor elsewhere. `gg`/`G` carry it to the ends.

`{`/`}` are the chrome's own motion, not a backend call, and they have to be. The backend's
prompt jump scrolls the viewport to a prompt **above** the screen, so it cannot reach any
prompt you are looking at, and in a pane with no scrollback it does nothing at all while three
prompts sit on screen. `ghostty.h` exposes no prompt marks (only a window-title action), so
moving a cursor to a prompt is not expressible. Vim's `{`/`}` key off blank lines anyway, which
are readable, and in a terminal a blank line is what separates one command's output from the
next.

That jump is named `scroll(.prompt(_:))` on ⌘⇧↑/⌘⇧↓, so both now ship and neither
replaces the other. `{`/`}` move a cursor within what you can see; the chord moves the
viewport and reaches what you cannot. Nothing above changed except who owns the chord.

So the motion walks the viewport: step past any blank rows the cursor already sits in, cross
the block of text, land on the blank after it. `TerminalSurface.text(viewportRow:)` reads one
row per call, because `read_text` goes through `selectionString` with `unwrap = true` and a
multi-row read comes back as logical lines with the row index no longer matching. The walk
stops at the first blank, so it is a handful of reads rather than one per row. Clamped to the
viewport: a paragraph off-screen needs the buffer moved first, which is what the page keys do.

A page move is the other case: it carries the cursor with the viewport, so your place on
screen is kept.

#### Selection and yank

`v` and `V` anchor a selection at the cursor; motions grow it; `y` copies it, drops back
to normal mode, and pulses what it took. The pulse runs after the write, not on the keystroke,
because a yank leaves nothing on screen and a copy that silently didn't take looks identical to
one that did. `Esc` hands the selection back before it closes anything.

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
reader never saw, so the anchor is given back the moment its row leaves the grid. That is driven by
the scrollbar report rather than by the key that asked, because the two do not line up in either
direction: output moves the viewport with no key at all, and a `j` at the end of the buffer moves
nothing while looking exactly like one that does.

**Inside the viewport the anchor is carried, not dropped.** A scroll moves every row by the offset
delta the report already carries, so the anchor rides it with no read at all, and the selection grows
by the rows that arrived. A reflow rewraps instead of scrolling, so the anchor is re-found by content
the way the cursor is: `ScrollSelection.anchorLine` is the anchor row's text, captured when `v`/`V`
opened it, and the re-find searches outward from the anchor's own row rather than the cursor's. A
blank anchor row has nothing to be found by and goes immediately, exactly as `cursorLine` does.

Both ends are re-found independently, and "nearest match" can settle on a repeated prompt, so a pair
that comes back **crossed** is dropped rather than painted: it would cover text nobody dragged over.
It is armed only when the cursor's own line is armed too, since a pair where one end moves and the
other holds changes the span without ever looking crossed.

**Between arming and the resolution the span stays painted, but cannot be read.** Those are separate
questions and the code answers them separately: `paintedSelectionRange()` keeps the last anchor so the
overlay and the header do not blink, while `selectionRange()` returns nil so nothing is yanked off a
row whose text may have moved. Hiding it instead was tried and reverted the same day: a held resize
reflows on every step, and the highlight strobed in and out under the reader's hands.

The read guard is not theoretical. `⌘E` and `⌘F` are reserved chords that never reach `handle`, so
they can ask for the selection before anything has placed its anchor.

**A key resolves the span, it does not drop it.** A reflow that rewraps nothing produces no report at
all, so the resolution may never arrive on its own; a keystroke is proof the grid has settled, so
both ends are re-found against it right there, before the keymap is asked whether a selection exists.
Both ends, never one: moving the anchor while the cursor holds its pending line resizes the span
silently, which no crossing test can see.

The three ways a selection is given back: its row leaves the grid, its row was blank so there is
nothing to find it by, or the two re-found ends come back crossed.

**A column is a character offset, and every consumer wants a cell.** The motions all move by
character, which is what vim means by a column, so the offset stays. The two places that need
cells convert: the rects `ScrollCursorView` draws, and the range a yank reads. A wide character
(CJK, an emoji) is two cells for one offset, and before the conversion the band drew a cell left
of true for each one earlier in the row while a yank ending past one stopped short.

`read_text` hands back a string with no per-character mapping, and there is no pin map to ask, so
`ScrollModeController.cells(of:)` finds it by binary search, and the search runs from the **right**:
reading cell *c* to the grid's edge gives every character from *c* on, so the row's own count less
that is how many sit before it. libghostty does the widths, so this cannot disagree with what its
renderer drew, which re-deriving them in Swift eventually would. A character counts as present once
the span touches any cell it occupies, which is what ghostty's own `selectionString wide char` test
pins down: selecting either half of a wide character returns the whole of it.

**Counting a prefix instead does not work**, and the first attempt did. The formatter drops a run of
never-written cells at the end of a read (`formatter.zig`: blanks accumulate and flush only when
something written follows), so a span stopping inside a cursor-positioned gap comes back short and
the search runs clean past it. A right-aligned prompt segment leaves exactly that gap, and the band
drew across the whole of it. Searching from the right is monotone whether or not blanks are dropped.

About seven reads per search, two searches per lookup, and only on a row that needs them: ASCII is
single width by definition, so an all-ASCII row maps straight through and costs nothing, which is
almost every row a terminal shows. Results cache per row beside `rowCache` and drop with it, because
the yank pulse refreshes the band sixty times a second and every read takes the renderer mutex.

A row's trailing blanks come off in `rowText`, not in the backend. `Surface.dumpTextLocked`
reads with `.trim = false` and the formatter keeps every cell a program actually painted, so a
row filled edge to edge (a prompt with a right segment, a status bar) arrives padded to the grid
width. Left on, `$` parks the cursor out in the padding and `v$y` copies a run of spaces.

### Find

⌘F opens a find bar along the bottom of whatever `modeTarget` resolves, a shown tool
float ahead of the focused panel. **The searching is libghostty's**: it matches, counts,
tracks which match is selected, and its renderer paints every highlight.
`SearchController` owns the bar, the needle, and the keys, and that is all the chrome
does here.

Three binding actions go down (`search:<needle>`, `navigate_search:next|previous`,
`end_search`) and four actions come back up (`START_SEARCH`, `SEARCH_TOTAL`,
`SEARCH_SELECTED`, `END_SEARCH`), relayed through one `onSearchEvent` closure rather
than four so the walk through the pane, tab and tool-float controllers stays one line.
All three land on `WindowController.report`, so the relays cannot drift apart. The needle
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

**The bar and a live prompt never coexist.** The bar being up means the keyboard belongs
to the search: to the field while the needle is typed, to scroll mode once ⏎ hands it
over. There is no third state, and every way out of scroll mode holds that, so `q`, `i`
and ⌘⇧S all take the bar down with the mode. `WindowController.wireModes` is where that
rule lives, on `scrollMode.onActiveChanged`, because `ScrollModeController` holds no
reference to the search and the coupling stays one-directional. It is re-entrant by
construction: `search.end()` tears down through `scrollMode.end()`, which lands back on
the same callback, and both controllers guard on their own `isActive`.

Left open, the hole was worse than a stray bar on screen. `search.isActive` kept the
app-global handler installed, `SearchController.handle` kept claiming `n` and `N`, and
`ScrollModeController.handle` declined everything once inactive, so the prompt went live
while silently eating the two keys that step a search.

**Search leaves behind only what it started.** Committing brings scroll mode up on the
reader's behalf, so Esc takes it back down: one keystroke to find something, one to be
done with it. A reader already in scroll mode when the bar opened put themselves there
and keeps it, which is what `didStartScrollMode` tracks. That is where Esc parts company
with `q`: Esc can leave a reader-owned mode up because the prompt stays dead either way.

The viewport is put back the same way. Stepping is the only thing here that moves it, so
`didMoveViewport` gates the restore, which scrolls back by the delta between where the
viewport sat when the bar opened and where it sits now. Back to the bottom is what that
usually means, because a search usually starts at a live prompt, but a reader already
scrolled into a build log gets that place back rather than the live end; `.bottom` is only
the fallback when no scroll report exists to measure against. It runs on the way out and
again whenever a needle stops matching: one character past the last match leaves the pane
parked on the previous needle's answer with nothing on screen matching what is now typed.
Neither fires for a search that never moved the viewport, and neither fires while the
reader is being left in a scroll mode of their own, where the match is what they asked to
be shown.

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
moves **up** the screen and the nearest occurrence that way is the one it selected. A step
that moved the viewport is the other case, and a scroll parks the match's own row at the
viewport top (`search/Thread.zig` scrolls to `flattened.startPin()` only when no viewport
chunk already overlaps), so the topmost occurrence is the answer. Case folding is
ASCII-only, matching the engine's `std.ascii.indexOfIgnoreCase`.

**Whether the viewport moved cannot be read off the scroll offset.** libghostty emits the
scrollbar report from the renderer thread and only while drawing a frame
(`renderer/generic.zig`: "The scrollbar is only emitted during draws"), while the selected
index is pushed straight from the search thread the moment the match is picked. So the
offset in hand when the selection lands is a frame or more behind, and comparing it against
the offset at step time answered "did not move" for a step that plainly did, whenever no
frame happened to land in between.

The screen itself answers synchronously instead: the search thread scrolls under the
terminal mutex before it reports (`search/Thread.zig`), so the rows read back are already
the ones on screen, and `rowsAtStep` holds the ones the step went out against. **The whole
viewport rather than the cursor's line**, because a screen of repeated prompts or repeated
log output can scroll onto text identical to the line the cursor left, and one line against
one line calls that standing still. It also asks nothing of the cursor, which is what makes
it right on the preview step, where scroll mode is not up yet and `scrollMode.cursor` is a
leftover from whenever it last was.

**A scroll parks the match at the top only when it can.** Against either end of the buffer
it cannot, and nothing lands on row 0. Taking the first occurrence on screen there is what
left the cursor a step behind the highlight on every downward step, catching up only on the
next press. Found at the machine, since the pure scan looks right until the viewport is
against an end.

The end is counted rather than guessed. A clamped viewport reaches a buffer end, so every
match between the selected one and that end is on screen, and the backend's index says how
many those are: stepping toward newer matches clamps at the live end, where the selected
match sits `selected` occurrences up from the bottom; stepping toward older ones clamps at
the top, putting it `total - 1 - selected` down from the first. Direction alone cannot do
this, and a first pass that took the bottom-most occurrence was right only while the
clamped screen held one candidate. When the count does not land inside the screen the
premise is off, most likely a soft-wrapped match the scan cannot see, and the fallback
takes the direction's end rather than inventing a cell.

**Search does not wrap, and that is libghostty's call**, not something the chrome hides:
`search/screen.zig` says so where it stops ("We don't wrap or reset the match currently"),
so stepping past the newest or oldest match does nothing. Nothing here should infer a wrap.

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

**The count reads in buffer order, and the backend's index does not.** libghostty walks
matches newest to oldest, so its zero-based `selected` counts down the screen while the
reader counts up it: reported straight through, the match a search first lands on read
`1 / 3` while sitting at the bottom of three. `FindBarView.showCount` shows `total -
selected`, so 1 is the match nearest the top of the scrollback, which is the one a reader
picks out by eye.

The four `search-*` colors are emitted from `Theme.current` by `AppTheme`'s init, so a
terminal theme cannot reach a surface without them. Candidates sit back toward the
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

**The cursor is a viewport row number, so a reflow has to re-find it by content.**
Anything that changes the grid's shape rewraps the text under that number: a font
step, the find bar taking a row, a window or divider drag. `surfaceGridDidReflow`
is the resize half, emitted from `GhosttyHostView.syncSizeAndScale` when a size
push actually moves rows or columns, and relayed to `ScrollModeController` per
surface so a drag that reflows one pane leaves the others alone. `refreshGeometry`
arms an anchor from the line the cursor is on and re-finds it on the first
`scrollPositionDidChange` after, then drops it: libghostty reports a scrollbar only
from a draw and only when the value differs, so a resize that rewraps nothing reports
nothing at all, and an anchor left armed fires on unrelated output much later.

**The line is remembered when the cursor lands, not when the reflow asks for it.**
libghostty derives the grid synchronously and mails the rewrap to its IO thread, so
by the time the event arrives the grid has already changed shape while the text has
not. A cursor sitting in the rows a shrink cut then names a row `text(viewportRow:)`
refuses, and reading at that moment returned nothing to find the line by. Capturing
it in `refreshCursor` instead means it is read while the grid still matches the row.
A geometry refresh is excluded from that capture, since it re-places the band against
a grid mid-reflow and a drag can fire several reflows before one report arrives. The
trade is staleness: output that rewrites the row under a still cursor leaves the
remembered line describing what used to be there. Refreshing it from the scroll report
would put a `read_text` on the output path, and one `tick()` can drain many lines in a
single turn, so that buys a main-thread stall instead.

**The re-find runs in three passes, because a rewrap leaves no row holding the whole
line.** `text(viewportRow:)` reads one row's cells, so a line that wrapped comes back
split. An exact match goes first, nearest to the old row winning because `❯ ` prefixes
every prompt on screen. Failing that, a fragment pass takes the row where one text
starts with the other: narrowing leaves a prefix of what was remembered, widening
leaves a row that has it as a prefix. Last, a containment pass, for a cursor parked on
a **continuation** row: that row holds a *suffix* of its logical line, so widening
merges it back in and the remembered text lands mid-row with neither string starting
with the other. It goes last because containment matches far more loosely, and a wrong
match moves the band where the stricter passes would have left it still.

All three rank by longest shared run rather than nearest, or a bare prompt a row away
would outrank the line the reader was on, and all three ignore matches too short to
mean anything. A height change needs none of this, which is why exact matching held up
until a width change was tried.

A selection's anchor comes back the same way, searching from its own row instead of the
cursor's, and is dropped on any of the three conditions above. The
overlay is refreshed either way: it holds the rects it was last handed, so releasing
without a redraw left the highlight painted over rows it no longer covered. A
viewport-relative cursor cannot follow a line off the screen at all: when the line is
gone the band holds its row rather than jumping to an unrelated one.

**The retractions are the load-bearing half.** The mode holds an app-global key
handler, so one left up deafens whatever you switched to. It ends when pane focus
moves (which covers pane close, split and tab switch, since all of them route
through `restoreUnifiedFocus`), when a tool float or modal card takes the keyboard
(neither moves pane focus, so neither fires the focus relay), and when the window
resigns key. `end()` is idempotent, so overlapping triggers are free.

**Focus Mode is the counter-case, and it caught us.** Zoom re-takes first responder after
the canvas reparents, and doing that through `focus(_:)` announced a focus move over the
pane the reader never left, ending the mode on every `⌘⏎`. `PaneCanvasController` gives
zoom `focus(_:announces:)` with the announcement off instead. Narrowing `focus(_:)` itself
to "the leaf id changed" does **not** work: pane close and tab switch both reassign
`tree.focusedLeaf` before calling it, and a drawer handing focus back names the leaf it
left.

Two things ride on that announcement that the zoom path then has to do itself. It re-asserts
the mode's unfocused render, since taking first responder paints the shell's live cursor back
underneath it. And it ends the find bar: the zoom pulls first responder off the field without
the bar hearing, nothing clears `isEditing` on a lost responder, and a bar left editing makes
the mode handler decline every key, so the whole keyboard goes to the shell behind it.

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
until the first save from Settings. There are no workspaces, so the ⌘⇧P picker
shows only its `＋ Add workspace` row.

`ToolFloatCatalog.all` is `builtIns + GeneralConfig.current.floats`, and `builtIns`
holds exactly one: **Scratch** (⌘;, a blank login shell), which is why the built-in
lives in the catalog rather than in `GeneralConfig` and the line above still holds.
It behaves the way a drawer does: one live instance per tab, kept running across a
dismissal, gone when its shell exits or its tab closes, and ⌘W on the last pane
confirms on a busy one. The one deliberate difference from a drawer is that a tab
change dismisses the card rather than carrying it. Two consequences worth knowing:

- **`scratch` is a reserved id.** A `float =` line whose title slugs to it is
  refused with a diagnostic, rather than shadowing the built-in. Its id keys the
  toolbar button, the Shortcuts row, the palette entry and the default chord, and a
  shadow would repoint ⌘; while all four still said "Scratch".
- **Its chord is edited on the Shortcuts card**, not on a Tools row. It is the only
  float chord that is: a user float's chord is the `key:` on its own `float =` line,
  and the built-in has neither a line nor a row. That makes `isEditableInSettings`
  answer true for the built-in and false for every other float, and it is where a
  chord conflict against it is reported.

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
  is only half the job; the next split lands at the config size otherwise.

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

**External hand-edits are picked up on demand only, via ⌘⇧,. There is no file
watcher.**

Both writers do a whole-file read-modify-rewrite over `ConfigFileIO`, which
centralizes two guards: never treat an unreadable existing file as empty (the
rewrite would erase the user's config), and write through symlinks (a config
symlinked into a dotfiles repo must keep pointing there). `ConfigWriter` preserves
comments, blank lines, and unknown keys verbatim.

**Theming is derived, never hardcoded.** `ChromeThemeDeriver` maps ANSI slots onto
nine chrome roles: background and foreground come from
the theme's own, info is ansi[4], warning ansi[3], destructive ansi[1], accent ansi[5],
attention ansi[6], positive ansi[2], and muted a blend of fg and bg.

Roles are named for meaning, not hue, which is why they are separate fields rather than
aliases onto a slot: repointing one leaves the others alone.
Sixty-five themes ship bundled; a user file shadows a bundled one of the same name. See
CLAUDE.md for the rule that the chrome never hardcodes a color.

**A role answers which color. Two other things answer how strongly.**

**Text and icons take one of four ink levels**, `faint` 0.35, `muted` 0.5, `subtle` 0.7,
`normal` 1.0. Every site asks for a level and never for a number, which is what stops a new
site inventing a weight between two of them: twenty-one hand-tuned alphas is what that
produced, and the things you click ended up at the weight of the hints beside them.

`faint` is for a thing quieter than what it sits beside: a disabled label, a hint opposite a
caption. It is the bottom of the ramp and the ramp is closed. A fifth level has nowhere to go
anyway, since `normal` pins the top at 1.0 and `subtle` is already 0.7, so a site that wants
one is the signal that the surface has too many tiers.

`inkBoost` (1.15) lifts all four, because dark ink on a light theme reads fainter at equal
opacity. **Check `1 / boost` before raising it.** A level above that threshold clamps to full
opacity, which is how the previous 1.3 made `0.95` and `1` paint the same color while looking
like two values.

**Fills are separate and an order of magnitude fainter**: hover washes, hairlines, dividers,
borders, active tints. There are three ways in, and which one a site takes is the whole
distinction.

**A control's interactive fills take a tier**, `chrome.fill(.rest / .hover / .active)` at 0.06,
0.10 and 0.15. `.active` is accent-toned; the other two come off the foreground. All three run
through the same `fillScale`, which is what guarantees the ordering: seven hand-tuned hover
values is what a per-control number produced, and one of them inverted. The fill alone never
carries the active state, so every `.active` site pairs it with accent ink or an accent ring.

**Structural fills keep a raw alpha** on `chrome.fill(alpha:)`, because nothing about a divider
can invert. Three named constants, because the same 0.08 previously meant a divider in one file
and a keycap background in another. They are a **weight scale, not a taxonomy of objects**:
`hairline` 0.08 is the quiet tier, `border` 0.10 the standard one, `swatchRing` 0.15 the loud
one.

Two of those weights have a reason a use-site name would hide. `swatchRing` is heavier because
it has to contain an *arbitrary* colour rather than sit on the theme background, or a dark
theme's black slot vanishes against the list card. And a mark's **length** decides which tier it
wants, not what kind of object it is: the dock's 1x12 group ticks take `border`, not `hairline`,
because a 12pt rule and a 400pt one do not read alike at equal alpha. Naming these after their
first consumer is what sent those ticks to the quiet tier and made them disappear.

**A standalone role-toned surface takes `chrome.tint(_:alpha:)`** and is deliberately *outside*
`fillScale`: `selectionFill` (a selected row, and the focus fill inputs share with it),
`badgeTint` (the accent square behind a card's icon glyph), the find bar's wash, the scrollback
selection and flash. These sit behind text, where the constraint is not to fight it, and
scaling one to 1.77 puts an accent at 0.37 under a caption.

**`fillScale` normalizes them per theme.** A fill is our invention, not the theme author's: a
0.10 wash of their foreground over their background lands wherever those two happen to sit,
and across the catalog that separation runs 0.40 to 0.94. The same border was 2.3 times
fainter in Solarized Dark than in Vesper. `ChromeThemeDeriver` derives a scale that holds the
achieved luminance delta constant instead, anchored to a fixed reference separation rather
than the catalog's median, so adding a theme cannot re-weight the existing ones.

It never scales *down*. A theme already better separated than the reference shows its borders
clearly, and dimming it to hit the target exactly would make what looks right look worse to
fix what does not. That floor is the whole residual spread, not the 1.8 cap, which no bundled
theme reaches. One test walks all sixty-five themes, which is what makes any of this
checkable without inspecting them by hand.

**Never `accent.withAlphaComponent`.** `fillScale` has to reach every fill inside one control or
their weights stop being comparable: a foreground hover scaled to 0.20 on a narrow-separation
theme out-weighed a fixed accent active fill at 0.14, so "recording your chord" read fainter
than the pointer merely being over it. That is why `.active` is a tier and not a `tint`.

**One pair genuinely does mix the two**, and it is the only one: `selectionFill` is an unscaled
focus fill sitting over a scaled `fill(.rest)` in every input and nav row. The margin holds at
the 1.8 cap (0.207 against 0.124), but it holds by arithmetic rather than by construction, so
it gets its own test. Any *second* such pair is the signal to move one side onto the other's
path instead of adding a second test.

**Text is deliberately not normalized.** At `normal` the ink is the theme author's own
foreground, chosen to be legible on their own background. Normalizing it collapses all four
levels into one color on a narrow-separation theme and buys no contrast, because `normal` pins
the top at 1.0 and the theme's own foreground-to-background distance is the real ceiling.

**A program can move one color, and only inside its own pane.** OSC 11 (and OSC 4/10/12) is
applied by libghostty *below* the seam. It writes the color into `terminal.colors` and its
renderer draws from there, so the grid follows a program whether the chrome reacts or not,
and there is no config key to stop it. What the chrome decides is how far that reaches
. `GHOSTTY_ACTION_COLOR_CHANGE` is the notification that lands afterwards, and the
background alone is carried up, as `surface(_:backgroundDidChange:)` plus the
`backgroundOverride` pull for a host built after the fact. It repaints the fill that pane
paints around and under its own terminal (`PanelHostView`, `SurfaceFloatOverlay`, and the
layer behind the grid), so a repainted pane doesn't sit inside a ring of the old color.
Every `ChromeTheme` role stays `Theme.current`: a program recolors its pane, never the frame
around it. Foreground, cursor and palette changes are dropped, because the terminal draws
those and no chrome surface repeats them.

**A chrome surface inside a pane paints on the pane's own fill, not its own tint.** Below
`background-alpha` a pane deliberately has no opaque fill: the clip stops filling so the grid
can show through, and `RingFillView` paints the padding at the pane's alpha. The chrome's
tints are alpha inks tuned for an opaque background, so the find bar's accent-at-0.14
composited onto whatever was behind the *window* and read grey. Every strip inside a
pane now takes the same fill the ring paints, with its tint over it
(`ChromeTheme.surface(tint:over:)`), pushed down by `PanelHostView.applyBackground` so an OSC
11 repaint carries into it too.

**Showing a strip has to mark the ring for redisplay by hand**, and only translucency reveals
it. The ring punches the terminal's frame out of the padding it paints, so a strip that resizes
the terminal moves that hole. Flipping a constraint does not mark the panel as needing layout,
and `layout()` is the only other thing that marks the ring, so the ring keeps the hole it
punched for the full-height terminal: the strip's band goes unpainted and the window's backdrop
shows straight through it. That band was the grey strip, measured off a screenshot as
*exactly* the backdrop's color rather than a washed-out fill. Focus Mode never showed it because
zooming resizes the panel itself, so `layout()` runs.

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
config sends all of them at once by naming an `AccentSlot` (an ANSI hue name).
The override is applied to the `accent` field alone inside the deriver, so the roles
that carry meaning stay put: a warning is not a taste. What makes this work with no
call-site changes is that nothing caches the color: `ConfigChange.between` sets
`.theme` from a whole-value `AppTheme` diff, and the existing `reapplyTheme()` fan-out
repaints even the sites that bake their color at init, like the tab bar's tracer.

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
- **No built-in lazygit or gitdash.** Scratch is the only built-in float; every
  other float is a user-authored `float =` line.
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
