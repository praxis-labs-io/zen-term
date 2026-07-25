# Architecture

What ZenTerm is, as it exists today. If a change makes this wrong, the change
fixes this file.

ZenTerm is the chrome around a terminal. Ghostty renders text and runs shells;
everything else here is ours. 116 Swift files, roughly 17.7k lines.

## The seam (load-bearing)

`TerminalSurface` (`Sources/TerminalKit/TerminalSurface.swift`) is the whole
contract, in 137 lines. A surface is anything that can *be* a terminal inside our
chrome: it vends an `NSView`, a title, a cwd, and a busy flag, and it takes
`start`, `focus`, `terminate`, `paste`, `copySelection`, `applyAppearance`.

Four types travel with it: `TerminalSurfaceConfig` (spawn params),
`TerminalSurfaceDelegate` (nine events out, all defaulted to no-ops),
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
(`bin/build-ghosttykit`). A fresh worktree needs `Frameworks/GhosttyKit.xcframework`
and `Sources/TerminalKit/Resources/ghostty-resources` symlinked in or the build
fails.

## The backend

`GhosttySurface` + `GhosttyApp` + `GhosttyHostView` + `GhosttyHostViewIME` +
`GhosttyConfigWriter`, all in `TerminalKit`.

- **libghostty config is app-global.** One `ghostty_app_t` per process.
  `applyAppearance` on any surface calls `GhosttyApp.shared.updateConfig`, deduped
  by generated config text, so N surfaces cause one real swap. A consequence:
  **there is no per-surface theming.** Every pane shares one theme.
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
- **Shader draw stops when nobody can see it.** The focus libghostty is told about
  is `paneFocused && isAppActive`, and `GhosttyHostView` reports its window's
  occlusion, so a backgrounded, covered or minimized window runs no shader draw
  timer at all (ZEN-271).
- **`GHOSTTY_RESOURCES_DIR` is force-overridden.** Launching ZenTerm from inside
  Ghostty.app would otherwise inherit a mismatched version's shell integration and
  terminfo.
- **`isBusy` is `ghostty_surface_needs_confirm_quit`**, which means "the cursor is
  not at a prompt," from OSC 133 marks. A shell ghostty cannot integrate reads
  busy, conservatively.
- **Re-entrancy:** actions that make the chrome free a surface defer to
  `DispatchQueue.main.async`. Doing it synchronously inside `ghostty_app_tick` is a
  re-entrant use-after-free.

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

`PaneCanvasController` (573 lines) owns the tree, the registry, per-leaf state,
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

`WindowController` (1320 lines) owns one window: its `TabList`, its
`TabController`s, the toast presenter, the tool floats, the single modal slot, the
tab bar, and the dock. `TabController` (1284 lines) owns one tab: a
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

**Tool floats are window-level, not app-level**, because a surface is one `NSView`
and can live in one view hierarchy: an app-global instance would physically yank
the float out of window A when opened in window B. `ToolFloatController` holds no
reference to any `TabController` and reaches the active tab through four injected
closures. Liveness and visibility are independent: `activeFloat` is the one shown,
`liveFloats` are the ones alive.

**Every silent no-op is a toast.** Focus-Mode-blocked commands, dead nav directions,
git-guarded floats, ⌘W over a float. Both toast paths throttle at 3s per verb
because held chords auto-repeat.

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
picker, ⌘, settings, ⌘⌥R reload. ⌘⇧- rather than bare ⌘- leaves ⌘- free for ghostty's text
magnification. **No tool float is built in**; a float's chord comes from its own
`key:` field.

`KeymapAssembler.assemble` resolves defaults, then float chords, then user
keybinds, later winning. **A user keybind moves its action**: the action's default
chords are dropped first, so the old key is freed rather than both firing.

**The modal gate cascade** in `WindowController.handle(_:)` runs confirm, then
modal card, then tool float, then dispatch. The app-global chords (⌘N new window,
⌘⌥R reload config, and the unbound-by-default Check for Updates command) bypass it on
the keyboard path (`AppDelegate.route`) and re-implement the gate by hand, because
they are app-global rather than window-scoped. A command-palette pick, though,
dispatches through `handle`, which forwards those same app-global chords back to
`route` via `WindowController.onAppGlobalCommand`. Without that they'd be a no-op in
`handle` (that's how Reload Config from the palette used to do nothing). Copy and
paste take a third path through the responder chain.

**The nav socket** backs [zen-navigator.nvim](https://github.com/zen-term/zen-navigator.nvim).
`NavSocketServer` listens on `~/Library/Application Support/ZenTerm/nav.<pid>.sock`
and exports it as `$ZEN_SOCK`. **Per-pid, not a well-known path**: a shared path let
a dev build bind over the installed app's socket and delete it on quit, leaving
every nvim deaf until relaunch. Failure is silent and non-fatal, because ⌘-nav never
depends on it. The wire contract is `docs/nvim-navigator-protocol.md`.
`NavGuard.shouldPassThrough` passes through only Ctrl-nav, never ⌘-nav, so default
pane nav is untouched whether or not the pane runs nvim.

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

**Live reload works because most call sites re-read.** `GeneralConfig.current` and
`Theme.current` are process-global mutable statics, and things like
`ChromeMetrics.panelGap` are computed properties that read them on every access.
The exceptions are already-built constraints and already-started shells, which is
exactly what `reapplyChromeLayout` and `applyAppearance` exist to fix up. **A
surface's shell is fixed for its life.**

`AppConfig` is the entire save-reload-apply seam: `persist` for a write, `reload`
for ⌘⌥R. Its order is load-bearing: general config first, then theme (which reads
the general font), then post `.configDidChange`. `GeneralConfig` reads nothing from
`Theme`, so the one-way dependency `Theme.current -> GeneralConfig.current` holds and
they cannot deadlock. The file I/O runs off the main thread and only the adopt and the
broadcast run on it (see the off-main note under "Sharp edges").

**External hand-edits are picked up on demand only, via ⌘⌥R. There is no file
watcher.**

Both writers do a whole-file read-modify-rewrite over `ConfigFileIO`, which
centralizes two guards: never treat an unreadable existing file as empty (the
rewrite would erase the user's config), and write through symlinks (a config
symlinked into a dotfiles repo must keep pointing there). `ConfigWriter` preserves
comments, blank lines, and unknown keys verbatim.

**Theming is derived, never hardcoded.** `ChromeThemeDeriver` maps ANSI slots onto
eight chrome roles: info is ansi[4], warning ansi[3], destructive ansi[1], accent
ansi[5], attention ansi[6], muted a blend of fg and bg. Fifteen themes ship bundled;
a user file shadows a bundled one of the same name. See CLAUDE.md for the rule that
the chrome never hardcodes a color.

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
- **Config writes go through `AppConfig.persist`: every file read runs on its queue and
  every parse runs on main.** A write is a whole-file read-modify-rewrite plus two reads to
  re-resolve, and Settings live-apply fires one every ~180ms while a control settles, so
  on a network-backed or cloud-synced home that is the ZEN-90 stall (ZEN-17). One serial
  queue carries writes and reloads: it replaces the ordering the main thread used to
  provide, without which two overlapping writes would both read the pre-edit file and the
  second would erase the first.

  **The parse cannot move off main**, and not for a reason the code shows locally: it
  assembles the keymap, which asks the keyboard layout what a chord can type, which is a
  Carbon TIS call. Off main that kills the process outright with no crash report, and
  `swift test` does not reproduce it. See "Carbon and the main thread" in
  `docs/swift-conventions.md` before moving anything here onto a queue.

  So a resolve is four hops: read `config` on the queue, parse it on main, read the theme
  on the queue (its name comes from the parse), build and adopt on main. A generation
  counter drops a superseded pass rather than letting it pair its own config with a newer
  theme, and `inFlight` is what lets a test drain the pipeline without knowing its depth.

  **The statics stay main-thread-only.** `GeneralConfig.current` and `Theme.current` are
  read by every view, so `adopt(_:)` takes a value rather than reading the file.

  **A caller that repaints from the reloaded config has to wait for it.** The ⌥↑/⌥↓ float
  reorder rebuilds from `GeneralConfig.current.floats`, so it rebuilds from the write's
  completion: rebuilding straight after the call redraws the list it already had and the
  float doesn't move (the ZEN-145 shape). The two Settings sections refresh from the
  completion and take **only the newest write**: writes are serialized, so an older
  completion carries a value the user has moved past, and a segmented control or dropdown
  (unlike a field, which skips itself while it has an editor) would flick back through it.
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
- **No tab drag-to-reorder**, no config file watcher, no scrollback search.
- **Three seam events are emitted with zero consumers**: `surfaceDidRingBell`,
  `progressDidChange`, and `surfaceWantsClose`. The backend translates all three,
  but nothing in the chrome implements them. Pane exit runs entirely through
  `surfaceDidExit`.
