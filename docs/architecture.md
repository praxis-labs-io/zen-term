# Architecture

How ZenTerm fits together today: structure and the constraints that shape the code. No
history, rejected designs, measurements or copy reasoning. Shortcuts live in `docs/config/config`.

## The seam (load-bearing)

`TerminalSurface` (`Sources/TerminalKit/TerminalSurface.swift`) is the
contract. A surface vends an `NSView`, a title, a cwd, a busy flag and the background
its program last reported. It takes `start`, `focus`, `terminate`, `paste`,
`copySelection`, `applyAppearance`, `setFontSize` and `scroll`, reports its grid as
`cellMetrics`, and reads its own screen back a row at a time (`text(viewportRow:)`,
wrapped rows split) or a span at a time (`text(in:)`, wrapped rows joined).

Types that travel with it: `TerminalSurfaceConfig`, `TerminalSurfaceDelegate` (events
out, defaulted to no-ops), `TerminalTheme`, `TerminalBehavior`.

**The rule:** if only one backend can do a thing, it stays below the seam. The
protocol grows only to hold what the chrome needs from any terminal.

Contract details that are not decoration:

- **`setFontSize` is separate from `applyAppearance`.** Appearance travels as a whole
  theme through app-global config, which costs a write and parse per value. Size takes
  an absolute value, never a delta, so the chrome owns the number.
- **`setFocused` is not `focus()`.** Cursor focus follows the chrome's single-focus
  model, not the responder chain, which is unreliable while many panes reparent.
- **`surfaceDidFailToStart` is delivered asynchronously**, never inside `start`, so a
  consumer has finished wiring the surface first.
- **`disposition(of:)` asks the backend what it would do with a chord.** It takes a
  `TerminalKey` (keyCode, modifiers, unshifted codepoint, typed text), not an
  `NSEvent`, because both callers ask about a chord nobody pressed. Both spellings
  travel because libghostty matches either. `ChordDisposition.mayClaim` means a
  conditional bind (runs only when the action does something); a probe cannot resolve
  it and must not round it up to `claims`.

### The backend's keymap

ZenTerm unbinds most of libghostty's keymap. `GhosttyUnboundChords` holds the
decision, and `GhosttyConfigWriter` emits one `keybind = <trigger>=unbind` line per
chord. What survives is `GhosttyUnboundChords.kept`: terminal encoding only (`⌘←/→`
to `^A/^E`, `⌥←/→` to word moves, `⌘⌫`, `⇧` arrow/Home/End/Page selection).

- `BackendShadowSweepTests` walks every typeable chord against a live surface and
  fails unless the surviving shadow is exactly `kept`. Re-run it on a ghostty pin bump.
- `BackendShadow` asks the same question at load time, because a user keybind can free
  a chord for the backend. `AppDelegate` runs it once a surface exists and
  `ConfigApplier` re-runs it when the keymap changes. It logs only.
- Its liveness canary (⌥←) catches a surface whose backend never started, where every
  chord reads `.ignores`. It must come from `kept`, or unbinding it reads as dead.

## Targets

```
GhosttyKit (binaryTarget: Frameworks/GhosttyKit.xcframework)
     ↑
TerminalKit          the ONLY target that may import GhosttyKit
     ↑
  PaneKit            imports no AppKit; TerminalKit for the seam types
     ↑
  ZenTerm            the chrome

  TabKit             pure leaf used by ZenTerm: imports nothing
  AppLog             Foundation + os leaf used by TerminalKit and ZenTerm
```

The package graph enforces the seam: `ZenTerm` has no `GhosttyKit` dependency, so an
import there is a compile error. `TerminalSurfaceFactory.make()` is the one place the
chrome asks for a terminal, and `SeamTests` proves the protocol is implementable with
no backend (`SpySurface`).

**GhosttyKit and its resources are gitignored and built per machine**
(`bin/build-ghosttykit`). A fresh worktree needs `Frameworks/GhosttyKit.xcframework`
and `Sources/TerminalKit/Resources/ghostty-resources` symlinked from the main
checkout. The ignore patterns are slashless because git does not treat a symlink as a
directory.

**Never call `Bundle.module` in shippable code.** In a real `.app` it checks the
bundle root and a build-machine path, then `fatalError`s, so it works on the build
machine and crashes for everyone else. Use `Bundle.zenResourceBundle(named:fallback:)`.

**Logging.** `Log` tees to `os.Logger` and `~/Library/Logs/ZenTerm/zen-term.log`
(off-main; `debug` lines only with `debug = true` or `ZENTERM_LOG_VERBOSE=1`). Export
Diagnostics (`DiagnosticsBundleBuilder`) and Report an Issue (`ReportIssueOverlay`)
share `SystemReport`, and never carry the environment or config.

## The backend

- **Config is app-global.** One `ghostty_app_t` per process. `applyAppearance` calls
  `GhosttyApp.shared.updateConfig`, deduped by generated text. There is no per-surface
  theming.
- **Config comes only from files.** `GhosttyConfigWriter` writes
  `$TMPDIR/zenterm-ghostty-config-<pid>` and never loads the user's
  `~/.config/ghostty`. Per-surface configs are cached by text because each push is a
  synchronous write and parse on main.
- **`updateSurfaceConfig` pushes one surface's config** (the cursor shader standing down
  on an unfocused pane). It must carry that surface's font size, or libghostty resets a
  stepped size to the config's.
- **A stepped font size stops following config.** `setFontSize` marks the surface
  `font_size_adjusted`, after which reloads skip its font, so the chrome re-pushes
  `SessionFontSize.points` after every `applyAppearance`.
- **The `theme` line names two settings-free files on purpose.** libghostty answers DSR 996
  from conditional theme state, which follows the pane's scheme only when `theme` is a
  light/dark pair with differing paths. The files hold only comments. On a pin bump, diff `ghostty +show-config` with and
  without the line: only `window-theme` may move.
- **Shader paths are absolute** (a relative one resolves against the temp config file).
  Shaders get sRGB colors; use them raw. Layer opacity follows `background-alpha` only.
  Only MIT-licensed shaders are bundleable.
- **`GHOSTTY_RESOURCES_DIR` is force-overridden** against Ghostty.app's inherited one.
- **Re-entrancy:** freeing a surface from inside `ghostty_app_tick` is a use-after-free,
  so those actions defer to `DispatchQueue.main.async`.
- **Teardown sweeps process sessions, not process groups.** libghostty's `SIGHUP` misses
  background jobs, `nohup` and children in their own group. `ShellSessionLedger` records
  every session; `ShellSessionReaper` sweeps those whose leader exited (`SIGTERM`, 150ms,
  `SIGKILL`, off-main), watching each leader with a kqueue exit source. A surface cannot
  name its own session (libghostty forks under `/usr/bin/login`), so nothing attributes
  and only leaderless sessions are swept.
- **Quit drives teardown by hand.** `windowWillClose` does not fire on termination, so
  `applicationShouldTerminate` tears down every window and waits (capped) on
  `ShellSessionReaper.drainForQuit` and the worktree removal tracker.
- **Every input event libghostty sees is an explicit `NSView` override.** Nothing
  catches the rest, so a missing override drops events silently. Modifier events carry
  which side moved (`ghosttySidedMods`, key events only; mouse callbacks take unsided
  `ghosttyMods` or every row redraws). `GhosttyHostView` forwards a release only for a
  press it reported, and that ledger is also what makes `modifiersDidChange` idempotent.
- **Key text is sent only from 0x20 up**; control keys encode from keycode and mods.

### What the backend will and won't do

- **`paste` is the real bracketed paste path** (`ghostty_surface_text`). Multi-line text
  arrives as one block and skips the unsafe-paste prompt. To submit, send `"\r"` as a
  separate `paste`.
- **Links open on ⌘-click only**; ⌘-hover shows `LinkPreviewView`.
- **No per-pane user variable.** `OSC 1337 SetUserVar` is unimplemented upstream. Pane
  signals ride the nav socket (`$ZEN_SOCK`, `$ZEN_PANE`).
- **Scrolling is whole-cell.** No config or shader changes it, and momentum phase is
  ignored.
- **A program can recolor its own pane only.** OSC 11 is applied below the seam;
  `surface(_:backgroundDidChange:)` repaints that pane's fill, reset included, and every
  `ChromeTheme` role stays `Theme.current`. Two gaps are upstream: a theme change after
  OSC 11 leaves that surface's background behind, and OSC 21 emits no change at all.

## The pane tree

`PaneKit`: no AppKit import, no global state, ids supplied by callers.

```swift
public indirect enum PaneNode {
    case leaf(PaneID)
    case split(id: SplitID, axis: SplitAxis, ratio: Double, a: PaneNode, b: PaneNode)
}
```

`PaneTree` is a value type. `.vertical` is side by side, `.horizontal` is stacked.
`closing(_:)` returns nil for "closed the only leaf".

**A running shell survives a restructure** in two halves:
`PaneSurfaceRegistry.apply(diff)` creates and terminates leaves and touches nothing
retained, and `PaneCanvasController.rebuildViews()` keeps `hostByLeaf` so hosts are
reparented rather than rebuilt.

`PaneCanvasController` owns the tree, the registry and per-leaf state, and is every
pane's `TerminalSurfaceDelegate`. Zoom changes only what `rebuildViews()` mounts at the
root. Resize swaps one constraint in place and clamps against the rendered extent
(`minSplitExtent`). `launchByLeaf` keeps the spawn config for `retryStart`.

## Windows, workspaces and tabs

`TabList` (TabKit) holds `order` and `activeIndex` for one workspace and always holds at
least one tab: `close` returns false when it removes the last tab. Tab numbers, tooltips
and keycaps derive from `order` at render time. A label is `pinnedTitle ?? liveTitle`.

`WindowController` owns one window: its workspaces, the toast presenter, tool floats, the
single modal slot, tab bar and dock. `WorkspaceController` owns one workspace: a `TabList`,
its `TabController`s and their titles. `TabController` owns one tab: a
`PaneCanvasController` and two drawers.

- **A window starts with one workspace, with no config entry**, and one workspace is
  always active. A workspace without a config entry is named "Workspace N", the lowest
  number no open workspace in the window holds. ⌘⌃T opens one at the end of the sidebar,
  in the home folder: a workspace is a place, and one opened on the focused pane's folder
  would collide with the open workspace already identified by it. A workspace is open when
  one with a config entry is open at its folder, so renaming it in Settings does not open a
  second copy.
- **Folder identity spans windows, so ⌘P never opens a second copy of a running
  workspace.** ⌘P opens a configured workspace, switches to it when this window holds it,
  and brings the window that holds it forward when another one does. A window cannot reach
  another, so it asks through
  `isWorkspaceOpenInAnotherWindow` and `revealWorkspaceInAnotherWindow`, which `AppDelegate`
  folds over its windows, skipping the asking one. A `WindowController` never raises its own
  window, so the ordering stays in `AppDelegate`.
- **The ⌘P picker groups into Open, Open Elsewhere and Configured**, and a workspace is
  listed once, in the strongest section that claims it. Open is this window's
  `WorkspaceOrder`, ghosts included and unselectable; Open Elsewhere is what the other
  windows report through `openWorkspacesElsewhere`, so an unconfigured workspace running
  elsewhere is listed too; Configured is what the workspaces file holds that no window has
  open. A worktree sits below its parent in whichever section the worktree itself belongs
  to, so a parent listed above is redrawn muted in Configured to hold the worktrees that
  are not open. Placement reads those lists, never `openState`, so nothing falls out of every
  section. `revealWorkspaceElsewhere` takes `(window, WorkspaceID)` because ids are minted
  per window and two windows can hold a workspace at one folder. That is a second pair of
  closures beside the folder-identity two above, not a replacement: folder identity
  deliberately ignores unconfigured workspaces and the enumeration does not.
- **`WorkspaceOrder` is the sidebar's order, derived from open order at every read.** A
  worktree workspace keeps the `WorktreeOrigin` it opened from and nests under the open
  workspace at its parent's folder, or under a ghost row built from that origin when the
  parent is closed. A group's first member mints its `seat` and later members inherit it,
  so the group holds its place as members close and reopen. A workspace with no config
  entry is never in a group. `navigable` skips ghosts; the sidebar's numbers, ⌘⌃1…9,
  ⌘⌃[ ] and a close's landing all read it.
- **`activate(_:)` is the single path a switch goes through**: a row click, the workspace
  chords, ⌘P, ⌘⌃T, and revealing a background tab. An open workspace slides in on the y axis, from
  below when it sits lower in `navigable`; a new one has no canvas yet, so it mounts
  without motion and applies its recipe in the same turn. A close's landing slides the same way.
- **A workspace has no view.** The window mounts a tab's own canvas, so an inactive
  workspace costs nothing beyond an inactive tab.
- **Tab ids are minted by the window**, not by the workspace, so they stay unique across a
  window's workspaces. Notification identity and the attention store's residual key on
  `TabID` alone.
- **A lookup by `TabID` searches every workspace; iteration for the tab bar reads the
  active one.** A tab's callbacks keep firing while its workspace is in the background, so
  `workspace(of:)` and `controller(_:)` span them all. Reading the active workspace where
  a lookup belongs fails silently.
- **Inactive tabs and workspaces are detached but retained**, so shells keep running.
- **Closing the last tab closes its workspace, and the last workspace closes the window.** A
  close that takes the window with it confirms first, so the window never goes unannounced.
  `closeWorkspace` is the single path a workspace goes through: ⌘⌃W closes each of its tabs,
  background ones first so nothing it closes is mounted, and the last tab's close lands on the
  row that takes its place in `navigable`.
- **Window stack, back to front:** canvas, tool float, tab bar, dock and sidebar, toast
  stack, modal card. Toasts sit above floats (the ⌘W guard toast is about the float); a card
  sits above toasts because it owns the keyboard. `closeModal()` in
  `select`/`addTab`/`closeTab` keeps a card from outliving its tab.
- **Hidden drawers are detached, not `isHidden`**: a 0x0 view resizes its PTY to zero
  columns and crashes TUIs.
- **Titles update on push**, re-read every 1.5s as a backstop that also polls drawer busy
  and agent exits, and lands a held idle that has no event left to push.
- **An agent's state is derived from the signals it already pushes**, by rules that are
  typed data in the repo, never configuration: `AgentStateRule` (a state, a priority, a
  region, a `contains`/`regex` matcher nesting through `any`), `AgentRules` (what ships),
  `AgentStateEngine` (pure; highest matching priority wins, a tie keeps the first). The
  regions are the two pushed signals, `oscTitle` and `oscProgress`. **No match falls back
  to `idle`, never `blocked`**: a false alarm costs more than a quiet row, so an agent we
  ship no rules for reads idle and still gets working from OSC 9;4. Codex emits no
  progress at all and its title carries all three states; Claude's title flickers to idle
  mid-turn while progress holds working, so Claude's title is read for the row's message
  and never for its state.
- **`AgentStateTracker` publishes transitions, not events.** It holds each agent's latest
  title and progress, and drops anything that does not move the derived state, because
  Codex's title changes on every spinner frame and its blocked title blinks. A
  working-to-idle fall that no rule explains is held briefly, because that is the shape a
  dropped spinner frame takes, and settles on its own timer since the agent then goes
  quiet; a rule that positively says idle is published at once. An agent's tracked state
  goes when it exits, so the next program in that pane starts clean.
- **Attention has one owner per window**, `AttentionStore`, keyed by `SurfaceID` across
  panes, drawers and floats. Each surface latches a `SurfaceAttention` beside a `seen`
  flag, and one ranked fold (`rollup`) is both the priority rule and the rollup at every
  level: surface, tab, workspace, window. A new level is a call, not a new concept, and
  the workspace level is that call: `state(tabs:)` takes the ids and the store learns
  nothing about workspaces.
- **`seen` means on screen, not focused.** A pane is on screen while its tab is active in
  the active workspace, a drawer while that holds and it is open, a float while it is
  shown. Coming on screen
  answers a surface and takes down the card it raised. A visit answers only what it puts
  on screen: a closed drawer or float keeps its latch and its card. Releasing an unseen
  surface folds its latch into a per-tab residual, so a closed pane does not unmark the
  tab it left; the next visit drops it.
- **An agent has a second latch that answering clears** (`agentState(of:)`), so a split
  asking in the active tab still reads waiting while its tab number stays quiet. It
  latches whatever the pane's focus, since the notification behind it comes only once,
  and focus does not clear it: looking at a prompt is not answering it. Answering is
  typing into the pane, where a key the chrome did not claim is aimed at the agent and a
  reserved chord is not. A turn ending (`working` falling)
  clears a waiting latch and leaves `completed`, here and nowhere else; a new turn
  replaces that, never a waiting latch.
- **`AgentRoster` says which surfaces run an agent**, per window: its name, where the name
  came from (`Source`, ranked so a stronger source renames, a weaker one never does, and a
  missing name yields to any real name), and what it last said. `identify` is the one way
  in. A launch whose program is `ai` or a known agent joins at launch, idle included; any
  surface that sends OSC 777 or indeterminate OSC 9;4 joins on that signal, and a title an
  agent's identification pattern recognises joins on that. The last is the only way in for
  a hand-launched Codex, which emits no progress and notifies on only some stops, and the
  only way a hand-launched Claude is listed, and named, before its first turn. An agent
  leaves when its surface is released, when its command finishes, or when its busy reading falls (the program exited to the
  shell), once its latch is answered. Only a *fall* from busy counts: a surface polled
  before its program starts has not been busy yet.
  The Agents rows join it with `agentState(of:)` and sort waiting (oldest first), working,
  done, idle, ties in sidebar order.
- **A state only the chrome can act on never reaches the tab number.** `working`
  says an agent is mid-turn, not that it wants you, so it stops at the dock's dot. The dot
  and the tab number are one signal at two altitudes; a hidden drawer or float asks
  through its dot because it has no number.
- **Background command completion:** OSC 133 `COMMAND_FINISHED` over a threshold in a
  background tab raises one sticky toast; the rank keeps it under a waiting agent.
- Notification identity is `(windowID, tabID)`; `TabID` is per window. `AttentionCenter`
  records which windows are asking and since when, and answers nothing else.
- `tearDown()` is idempotent, the single close path, and cancels pending confirms and
  keybind capture (a stranded capture swallows every key app-wide).

## Chrome

| Surface | Owner | Scope |
|---|---|---|
| Bottom and right drawers | `TabController` | per tab |
| Focus Mode (internally `zoom`) | `TabController` + `PaneCanvasController` | per tab |
| Fill Screen | `WindowController` | per window |
| Sidebar | `SidebarController` | per window |
| Tool floats | `ToolFloatController` | per window (Scratch per tab) |
| Settings, palette, workspace picker | `WindowController.modal` | per window |
| Toasts, confirms | `ToastPresenter` | per window |
| Terminal font size | `SessionFontSize` | per app |

- **Drawers are tiled.** Sizes are multiplier constraints at `.defaultHigh`. A drawer
  slides in at its final size while the canvas resizes, so the terminal reflows once.
- **Focus Mode is strict:** split, nav, resize and drawer toggles raise a toast.
- **The sidebar owns the canvas's leading edge.** The canvas and tool floats start from
  `SidebarController.canvasLeadingAnchor`, and the tab bar starts from the collapsed
  lead's trailing edge; modals and toasts stay window-wide. Canvases mount in a host that
  runs from the sidebar's edge to the tab bar's. While a canvas slides, the host's mask
  (`EdgeFade`) keeps it opaque to that edge and fades it out just past it, under the chrome;
  resting content is never faded, so nothing jumps when the mask lifts.
  Docking slides through `Motion.drawerSlide`, the drawers' path, holding the active
  tab's grids so they reflow once. Rows read the window's workspaces,
  never a copy. A new window opens the way the last toggle left one, for the launch only.
  The keyboard enters only through `focus_sidebar`, which brings a collapsed sidebar up
  first, and through nav with no neighbor to the left (`TabController.focusPastLeftEdge`)
  from the active tab, so panes, drawers and the nvim navigator all reach it.
  ↵ activates a row as a click does. Rows take focus from the keyboard only
  (`SettingsNavRow.takeKeyboardFocus`): AppKit promotes any clicked view that accepts.
  A right-click or ⌃-click opens `SidebarRowMenu`, a `ListPopover` that never switches
  workspaces; a local event monitor closes it on Esc or a click outside it.
- **Collapsed, the sidebar still reveals from the window's leading edge.**
  `SidebarEdgeReveal` watches an 8pt strip there, measured from where a hand aiming at the
  edge comes to rest, and floats `SidebarColumn` as a card over the panes after a hold.
  Leaving puts it away after a grace; both are static and test-overridable. Nothing resizes,
  and `isDocked` never moves, so the reveal is not a dock. Exit direction decides: running
  off the window's own edge is reaching for the card and keeps it, while leaving past it or
  through the top or bottom hides it. It is pinned by focus in the card, an open row menu or
  confirm, and suppressed by a modal, a tool float, a window that is not key, or a held
  mouse button. Suppression has to be explicit because tracking is geometric, not
  hit-tested.
  **Two toggles exist.** The card carries one and the window keeps one for the collapsed
  sidebar, because the card's rides in and out with it while the window's holds its spot
  through a dock slide. They are only ever swapped while the card covers that corner, and
  docked they resolve to the same frame.
  **A window under `SidebarController.minimumDockableWidth` cannot dock**, that floor being
  the window's own minimum plus the sidebar's. There the toggle floats the card instead,
  and taking the window below it while docked makes the sidebar yield to collapsed without
  changing the remembered choice. ⌃⌘S docks and collapses above that width and floats
  below it.
- **Fill Screen** is a maximize, not native fullscreen. `window-chrome = false` hides
  the traffic lights and `ChromeMetrics.topInset` follows.
- **Tool floats are window-level** because a surface is one `NSView`. `ToolFloatController`
  reaches the active tab through closures. `ToolFloat.Scope.tab` floats are filed under
  `tabID/id` and shut down with their tab; Scratch is the only one.
- **Every silent no-op is a toast**, throttled at 3s per kind because held chords repeat.
- **A surface stating current state is retracted when the cause clears.**
- **A toast's keys live on the card root** (`ToastView.performKeyEquivalent` and
  `keyDown`). A confirm refuses Space. A non-modal sticky card claims no keys;
  `dismiss_toast` and `dismiss_all_toasts` exist for the keyboard.

### The interaction language

New modal surfaces compose the existing primitives.

- **Primitives:** `AppButton` (variants `primary`, `secondary`, `muted`, `destructive`,
  `segment`, `link`), `SegmentedControl`, `FieldBox` + `LabeledField`, `ModalCard.swift`
  for card chrome and scrolling, `FormCard` for forms (body scrolls, footer pinned,
  capped at `FormCard.maxHeight`).
- **Keyboard model:** ↑/↓ between rows, ←/→ within a row, Return advances, ⌘Return
  submits, Esc cancels. Every card is fully operable without a mouse.
- **Input focus** is driven from `becomeFirstResponder` and `controlTextDidEndEditing`;
  a field's `resignFirstResponder` never fires because the field editor is the responder.
- **Scrolling lists** use a flipped document (`FlippedView`) plus `SlimScroller`, and no
  horizontal `contentInsets`. `KeyboardFocus.reveal(_:among:)` scrolls to the selection,
  unanimated, padding only the arriving edge.
- **`Motion.swift` constants are an approved baseline.** Do not re-tune them quietly.

## Key handling

**`KeyInterceptor` is an app-wide local `NSEvent` monitor** that resolves chords before
the responder chain. A control's own `keyDown` test can pass while the key never reaches
it.

`KeyInterceptor.route(_:)` order: capture mode consumes everything; `flagsChanged` fans out
and passes; a chord resolves; whatever is left goes to `modeHandler`, then the PTY.
`modeHandler` sits below chord routing so a mode never swallows ⌘T or the palette.

- **`flagsChanged` reaches every surface**, since mouse mods are per surface. Only one on
  screen in the key window takes a press; any takes the release it is owed.
- **`Route` has two ways of not consuming.** `passThrough`: nothing claimed it, a mode may.
  `deferToTerminal`: a chord matched and `passThroughGuard` handed it to the program
  (Ctrl-nav over nvim), so nothing else may touch it.
- **A mode declines ⌘ and ⌥ keys** it does not map, because menu equivalents (Copy,
  Quit) resolve after the monitor.
- **`GhosttyHostView.performKeyEquivalent`** reclaims Ctrl-Return and rewrites Ctrl-/ to
  Ctrl-_, and declines other ⌘/⌃ keys once so menus win.
- **`Chord` folds a shifted glyph onto its base key only when Shift is set.** The fold
  table is US-only; a non-US layout can mislabel a chord but never invent one. Keys that
  type no character are named by keyCode (`specialKeyGlyphs`), written as words in config
  (`home`, `backspace`) and as glyphs in the app.
- **`KeymapAssembler.assemble`**: defaults, then float chords, then user keybinds, later
  winning. A user keybind moves its action, dropping its defaults. `= none` is a value:
  `KeymapOverrides` carries `binds` and `unbound` so `ConfigWriter` does not delete the
  line. One chord per action; increase font size is the exception (⌘= and ⌘+).
- **A verb a text field owns is served from the Edit menu, never the keymap.** Select
  All, Copy, Paste, Cut, Undo and Redo are nil-target menu items so a focused field takes
  them first. A view with its own selection model must answer `selectAll(_:)` itself.
- **`TextEditingChords`** lists chords a text view owns (⌘⇧↑/↓, ⌘⏎, ⌘⇧⏎) so the
  interceptor defers them while a text view is first responder.
- **macOS takes ⌘⌥D, ⌃⌘D, ⌘↑ and ⌘↓ first**; a chord bound there is dead while tests pass.
- **Chord conflicts** get one sticky card each (`KeybindConflict`,
  `ConfigApplier.surfaceConflicts`). Accept writes `= none` for the loser; Revert returns
  the winner to its defaults. A user float that takes a chord gets Accept only; one that
  loses it gets Revert only. Settings rows show the conflict but do not resolve it.
- **The modal gate** in `WindowController.handle(_:)` runs confirm, modal card, tool
  float, then dispatch. App-global chords bypass it in `AppDelegate.route`; a palette pick
  of one returns there through `onAppGlobalCommand`. The sidebar toggle passes through an
  open card, which stays open. A card swallows other chords; a float
  raises a notice for pane commands and passes reading chords to its own buffer
  (`modeTarget`).
- **Picker chords go through `PickerChordGuard`** (⌥⏎, ⌘⇧⌫), because a bound chord is
  otherwise consumed app-wide and those keys belong to shells and TUIs. A focused sidebar
  row claims ⌥⏎ too.

**The nav socket** backs zen-navigator.nvim (`docs/nvim-navigator-protocol.md`).
`NavSocketServer` listens on `~/Library/Application Support/ZenTerm/nav.<pid>.sock`,
exported as `$ZEN_SOCK`; per-pid so a dev build cannot unlink the installed app's socket.
Failure is silent. `NavGuard.shouldPassThrough` passes Ctrl-nav only. An open tool float
also claims Ctrl-nav and gets no `$ZEN_PANE`.

**The theme state file** backs zen-theme.nvim (`docs/nvim-theme-protocol.md`).
`ThemePublisher` writes `~/Library/Application Support/ZenTerm/theme.json` at launch and
on every theme change. It is a fixed path because a float launches with no environment.
Bundled themes carry an `nvim-colorscheme` key.

### Scroll mode

⌘⇧S. `ScrollModeController`, one per window, targets the `TerminalModeHost` that
`modeTarget` resolves (a shown float, else the focused panel) and does not follow focus.
`ModeChrome` hangs the header, find bar and cursor off the host.

- `ScrollKeymap.key(for:pending:hasSelection:)` is a pure decode; counts and two-key
  commands arrive as `Pending`. Every key is consumed except unmapped ⌘ and ⌥ keys.
- **The cursor is the chrome's.** `ScrollCursorView` paints the band, cell, selection and
  yank pulse from `TerminalCellMetrics`, read at draw time and converted from backing
  pixels. It returns nil from `hitTest`. `GhosttyConfigWriter` emits `window-padding-x/y`
  so the grid origin cannot move on a pin bump.
- **Entry** lands on a mouse selection's first cell, else the last written row. The row is
  read before the header shows, because the header's reflow makes shells clear the prompt.
- **Page moves advance the cursor; the viewport follows** as far as it can.
- **Live output does not move the screen.** A report where the buffer grew by exactly
  the viewport's move is pulled back. A reflow looks identical, so `refreshGeometry` arms
  a suppression stamp. At the scrollback cap nothing is observable.
- **The cursor is a viewport row, so a reflow re-finds it by content.** The line is
  captured when the cursor lands (`refreshCursor`), and re-found in three passes: exact,
  prefix fragment, then containment, ranked by longest shared run.
- **A selection cannot leave the viewport.** `Point.pin` clamps every coordinate to the
  grid, so off-screen text cannot be read. `ScrollSelection` holds the anchor only; it is
  carried through scrolls, re-found through reflows, and dropped when its row leaves,
  was blank, or the ends come back crossed. `paintedSelectionRange()` keeps painting
  while `selectionRange()` refuses to yank an unresolved span.
- **A column is a character offset.** `ScrollModeController.cells(of:)` maps it to cells
  by binary search from the right (the formatter drops unwritten trailing cells). ASCII
  rows skip it. `rowText` trims trailing blanks.
- **Retractions:** the mode ends on pane focus change, float or card taking the keyboard,
  and window resign. Zoom refocuses with `focus(_:announces: false)` and must end the
  find bar itself. The stand-down is lifted off the controller it was pushed at.

### Find

⌘F. **Searching is libghostty's**: matching, counts, selection and highlights.
`SearchController` owns the bar, needle and keys. Binding actions go down (`search:`,
`navigate_search:`, `end_search`) and the `SEARCH_*` actions come back as
`TerminalSurfaceDelegate` search events.

- **Two keyboard phases.** While the field has focus the mode handler claims nothing.
  ⏎ hands focus back, starts scroll mode, and `SearchController.key(for:)` takes
  `n`/`N`/⏎/⇧⏎/Esc.
- **After ⏎ the bar never outlives scroll mode:** `WindowController.wireModes` ends search
  whenever scroll mode ends. Esc ends scroll mode only if search started it
  (`didStartScrollMode`), and restores the viewport only if search moved it
  (`didMoveViewport`) and the reader does not own the mode.
- **A match only in history is previewed once per needle** when none is on screen.
- **The match cell is inferred.** `SEARCH_SELECTED` carries only an index. `matchCell`
  scans the viewport by direction (libghostty walks newest to oldest), checks whether
  the viewport moved by comparing rows (`rowsAtStep`), not the scroll offset, which lags
  by a frame, and counts from the clamped end when the viewport hits one. Case folding
  is ASCII-only.
- **No wrap** (upstream), and **one-line needles** (everything downstream is per row).
- The count shows `total - selected`, so 1 is the topmost match.

## Config

Root is `$XDG_CONFIG_HOME/zen-term/` or `~/.config/zen-term/`: `config`, `workspaces`,
`theme`, `themes/<name>`. A fresh install writes nothing until the user saves a change in the app.

- **Nothing here can crash the app.** Missing, unreadable, typo'd and out-of-range values
  fall back per key, log once, and collect a `ConfigDiagnostic` shown on the owning
  Settings row and in a reload toast.
- `docs/config/config` ships fully commented out; `ReferenceConfigTests` asserts it
  parses to `.builtIn`.
- **`ToolFloatCatalog.all` is `builtIns + GeneralConfig.current.floats`.** Scratch (⌘;)
  is the one built-in, one per tab. `scratch` is a reserved id, and its chord is edited on
  the Shortcuts card.
- **`SessionFontSize.points`** is the running size, never persisted, bounded by
  `SessionFontSize.range`. It re-seeds inside `AppConfig.reload()` before the broadcast,
  only when `font-size` moved, and new surfaces are spawned with it.
- **Live reload works because call sites re-read** `GeneralConfig.current` and
  `Theme.current`. Built constraints and live surfaces are fixed up by
  `reapplyChromeLayout` and `applyAppearance`. A surface's shell is fixed for its life.
- **`AppConfig.reload()` order:** general config, then theme, then post
  `.configDidChange`. `AppConfig.loadAtLaunch()` does the first load; the statics are not
  lazy (see "Carbon and the main thread" in `docs/swift-conventions.md`).
- **The broadcast names what moved** (`ConfigChange`); no change set reads as `.all`.
  Gate on what a call chain reads, not what it is named after, and default to
  `.theme || .keymap`. `surfaceConfigDiagnostics()` stays ungated because it has its own
  delivery-aware gate. `ConfigFanOutDifferentialTests` and
  `ConfigApplierDifferentialTests` assert the gated fan-out matches the ungated one.
- **The config-problems notice is replaced all-or-nothing** in
  `WindowController.deliverConfigDiagnosticsNotice`, and retracted by `ConfigApplier`
  only when problems clear.
- **No file watcher.** Hand edits apply on ⌘⇧,.
- **Writers go through `ConfigFileIO`:** never treat an unreadable file as empty, and
  write through symlinks. `ConfigWriter` preserves comments and unknown keys.

### Theming

`ChromeThemeDeriver` maps ANSI slots onto chrome roles (info ansi[4], warning ansi[3],
destructive ansi[1], accent ansi[4], attention ansi[6], positive ansi[2], muted a fg/bg
blend). Sixty-five themes ship; a user file shadows a bundled one. `accent-color` repoints
`accent`, and the search highlight when the theme sets no search colors. The usage rules are CLAUDE.md's Colors section.

- **Ink levels** `faint` 0.35, `muted` 0.5, `subtle` 0.7, `normal` 1.0, lifted by
  `inkBoost`. Check `1 / inkBoost` before raising it: a level above it clamps to 1.
- **`fillScale` normalizes fills per theme** against a fixed reference separation, never
  scaling down. Text is not normalized.
- `selectionFill` over `fill(.rest)` is the one pair mixing scaled and unscaled fills, and
  has its own test.
- **A strip inside a pane paints on the pane's fill** (`ChromeTheme.surface(tint:over:)`),
  because below `background-alpha` 1 a tint alone composites over the window backdrop.
  Showing a strip must mark the padding ring for redisplay.

## Worktrees

`WorktreeStore` lists, creates and removes a repo's worktrees. Headless and blocking; callers
hop off-main. The ⌘P picker lists them under each workspace, creates with ⌥⏎ and removes with
⌘⇧⌫. A workspace's sidebar row creates them too, with its hover ＋ or ⌥⏎, and reads the
workspace's entry fresh for the card. Settings does not list them.

- **Git is the whole registry** (`worktree list --porcelain -z`): record one is the main
  checkout, `prunable` records drop, and only a create rollback prunes.
- **Rows group on `git rev-parse --git-common-dir`**, canonicalized, not `GitRepo.repoRoot`.
  The first workspace in config order with worktrees claims a common dir.
- **Location:** `~/.zenterm/worktrees/<repo-slug>-<digest>/<branch-slug>`, keyed on the
  main checkout. Branch slugs are lossy, so `destinationExists` names the holding branch.
- **A workspace inside a repo belongs to the repo.** The worktree is cut and keyed at the root
  and holds the whole tree, so the tab and `carry` land at `GitRepo.mirrored`: the workspace's
  own folder in the new checkout. When the base branch has no such folder, `mirrored` is nil:
  the tab opens at the worktree root and `carry` skips every entry as
  `workspaceNotInTheWorktree` rather than copying to the root.

### Creating

`create` takes a `Base`: `.defaultBranch` (`origin/HEAD`, `origin/main`, then local
`HEAD`) or `.currentCheckout`. `unbornHead` for a repo with no commits.

- **Branch names are validated before any mutating command**, and a leading dash is
  rejected by hand (`check-ref-format` accepts `-m`).
- **Branch and folder are claimed, not checked:** `git branch --no-track -- <name> <base>`
  (or `push.default=simple` refuses the first push), then
  `createDirectory(withIntermediateDirectories: false)`, then `worktree add` without `-b`.
  The rollback deletes only what was claimed, and leaves a branch that moved.
- **Rollback order:** `worktree remove --force`, directory, `prune`, then `branch -D`.
  Unfinished steps are named in `rollbackIncomplete`.
- **Existing branch** (`create(existingBranch:in:)`): no branch claim, and the rollback never
  touches the branch. It refuses a branch held by a linked worktree or a dirty main checkout
  (unreadable counts as dirty, via `holders(in:)`), and one with no local default to move to.
  A clean main checkout moves to the local default after the folder claim, and back on failure.

The create card replaces the picker and reopens it on cancel. `BranchField` is a `FieldBox`
plus `ListPopover`, Esc handled in its `doCommandBy`. `CreateTarget` carries the repo to
branch in and the workspace to carry from.

### Carry

The workspace `carry` key names ignored files to copy into a new worktree.
`WorktreeCarry.copy` reports what did not arrive and never throws.

- **Picked, never typed:** the workspace form lists `git status --porcelain --ignored`
  merged with existing `carry` entries. A folder spraying ignored files folds to one row;
  folded files stay searchable. Users read "copy", the key stays `carry`.
- **Allowlist, not denylist.**
- **`copyfile(3)` with `COPYFILE_CLONE`**, which falls back to a byte copy across volumes
  and keeps symlinks as symlinks. An entry that is itself a link out of the workspace is
  refused.
- **Refusals:** tracked files (a tracked folder copies only its ignored contents), unreadable
  repos, entries resolving outside the workspace (checked on resolved paths), and destinations
  that exist (`COPYFILE_CLONE` onto a directory returns 0 having copied nothing). Parents are
  created first; a partial copy is removed. Errors use `strerror_r`.

### Removing

- **`remove` is `git worktree remove --force`**, not cancellable. Locked worktrees are
  refused; the branch is untouched.
- **`state`** returns every uncommitted and untracked file (`--porcelain=v2
  --untracked-files=all -z`), or nil when git cannot be read. Lost commits are
  `rev-list --count HEAD --not --glob=refs/*` plus other worktrees' HEADs, run on every
  removal.
- **The confirm is `ConfirmCard` over the picker**, hosted by `RepoPickerOverlay`.
  `WorktreeRemovalMessage` builds its items (pure, tested); `ConfirmCardChecklist` and
  `ConfirmCardList` draw them; lists cap at 8 rows via `WorktreeRemovalRollup`. The read
  runs off-main and presents only if the same picker is still up.
- **`WorktreeRemovalTracker` is app-wide and runs the delete**, because closing tabs can
  close the window first. A removing row reads `Removing <name>…`. Tabs close on
  `Change.removed`, never on confirm or `failed`, matched by `TabController.openedCWD` or
  by the workspace's `WorktreeOrigin`, and closing them leaves the card up. The finish re-lists.
- **An open worktree row removes like a Configured one.** It reads `Removing <name>…` while
  the tracker holds it, and the finish rebuilds Open from `runningWorkspaces()` and drops
  Open Elsewhere rows inside the path, with a closed parent's ghost once it has none.
- **A worktree removed outside ZenTerm stays open, marked `removed`.** The title poll checks
  `<worktree>/.git` off-main, skipping a path the tracker is removing and an unmounted volume.
  The sidebar and picker read `WorkspaceController.isWorktreeRemoved`, and an open picker in
  any window refreshes when it flips. A toast says so once and offers Close Workspace, ⌘⇧⌫
  on its picker row does the same, and the mark clears if `.git` comes back. It never auto-closes, because
  an agent in its panes may still be running. A session that would inherit a folder inside it
  (a split, drawer or float, and a tab or window under `tab-inherit-cwd`) starts at the parent
  workspace's folder instead (`WorktreeOrigin.relocating`).

### GitCommand

`GitCommand` holds the app's only `Process()` sites, blocking by design. Both pipes drain
concurrently before `waitUntilExit`, or a full stderr buffer deadlocks. It gates on
`xcode-select -p`, since `/usr/bin/git` without Command Line Tools opens a system prompt.

## Invariants that will bite you

- **Closures capture by id, never by object.**
- **Unified focus is chrome-owned.** `TabController.focusedPanel` is the source of truth.
  The sidebar holds focus as the first responder on a row and leaves `focusedPanel` alone,
  so Esc, ⌘⌥→ and collapsing return to that panel through `restoreFocusToActive()`.
- **`HostWindow.isReleasedWhenClosed = false`**, or close underflows the retain count.
- **`ShellLaunch.program` re-arms zsh's `ZDOTDIR`**, or an `exec`'d shell loses shell
  integration (no OSC 7, no prompt marks, broken `isBusy`).
- **`ShellLaunch.program` brackets an *agent* program in its own OSC 133 `C`/`D` marks.**
  The wrapping `-c` shell runs no prompt hook, so without them the agent's exit reports
  nothing and an agent that exits before the first busy poll sits in the Agents list
  forever. Both marks are needed: libghostty drops a `D` that no `C` preceded. The `D`
  mark carries `$?`, or `$status` under fish. Non-agent programs stay unmarked, or every
  workspace program would reach `commandFinished` and toast on exit.
- **`ApplePressAndHoldEnabled` is registered false at launch**, or the accent popup leaks
  keys into the shell.
- **`GitRepo.repoRoot` stops when the path stops shrinking**, not on `parent == dir`, and
  **refuses `$HOME` as an enclosing repo**, or dotfiles at `~` claim every folder under it.
- **The `workspaces` file loads off-main** (`ConfigLoader.loadWorkspaces`). A card that
  renders it is built after the load; `pendingModal` tracks the press in between.
- **Interactive git probes go through `GitRepoStatus`.** It resolves and caches the
  enclosing repo, reads the branch off that root (`GitRepo.currentBranch`), and runs churn
  (`git --no-optional-locks status --porcelain=v2 --branch`, repo-wide) on `churnQueue`
  (width four) with per-caller cancel tokens. No probe fetches.
- **A float open is cancellable during its repo-root probe** (`cancelPendingOpen()`).
- **Palette rows are reused**, so they never carry an index; order is the stack's arranged
  subviews.
- **Swift's sort is not stable**, so floats sort by `(order, parse position)`.

## What does not exist

- No web panes, no built-in floats besides Scratch, no second backend
  (DEBUG `makeOverride` is for test stubs).
- No session restore or detach/reattach, no smooth scroll, no tab drag-to-reorder.
- `surfaceDidRingBell` is emitted with no consumers.
