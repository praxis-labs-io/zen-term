# Epic 3 — Drawers + lazygit float

**Status:** Approved (design)
**Date:** 2026-07-06
**Depends on:** Epic 1 (pane canvas), Epic 2 (tabs + windows, live cwd)

## Goal

Generalize the QuickTerminal pattern into a toggleable overlay layer: per-tab
bottom and right drawers, a per-tab lazygit floating overlay, a global left
sidebar, and a global toggle dock that mirrors the active tab's overlay state.
Drawer/lazygit contents are just more `TerminalSurface`s behind the seam.

## Scoping decisions (locked)

- **Bottom drawer, right drawer, and lazygit float are per-tab.** Each tab owns
  its own overlay surfaces — some drawers hold long-running processes tied to that
  tab, so they must persist independently.
- **The left sidebar is global** (per-window), spanning all tabs. It ships **last**
  in the epic as a minimal panel shell; its content (sessions/SSH/snippets) is the
  Epic 4 workspace model and is out of scope here.
- **Drawer shells are persistent per tab.** Created lazily on first open;
  toggle-hide keeps the shell + process **alive** (view detached, surface retained)
  — surviving both hide/show and switching to another tab; terminated only when the
  tab closes.
- **Drawer sizes are static this pass** (no drag-resize): bottom ≈ 240pt tall,
  right ≈ 360pt wide. Resizing is deferred.
- **lazygit auto-closes when its process exits**; Escape or backdrop-click also
  dismisses.
- **The toggle dock is one global widget** that mirrors the **active tab's** overlay
  state and updates on tab switch.
- **`⌘F` zooms the focused terminal** (a pane OR a drawer) to fill the tab region,
  as if it were the only terminal in the tab, with a zoom indicator. Toggling off
  (or Escape) restores the prior layout.

## Architecture — per-tab `TabController` wrapper

A tab is currently exactly one `PaneCanvasController` (pane tree). Epic 3 adds
per-tab overlays, so we introduce a per-tab wrapper rather than bloating
`PaneCanvasController`:

```
WindowController (one window)
 ├── global left sidebar (per-window, toggleable)     [PR4]
 ├── toggle dock (global widget, mirrors active tab)   [PR3]
 └── [TabID : TabController]                            ← was [TabID: PaneCanvasController]
      └── TabController (one tab)                       [PR1]
           ├── PaneCanvasController (pane tree)         ← unchanged (Epic 1/2)
           ├── bottomDrawer  : TerminalSurface?         [PR1]  ⌘B
           ├── rightDrawer   : TerminalSurface?         [PR1]  ⌘|
           └── lazygit float : TerminalSurface?         [PR2]  ⌘G
```

`PaneCanvasController` is unchanged and stays focused on the pane tree.
`TabController` owns it plus the auxiliary overlay surfaces, lays them out around
the pane canvas, and forwards the tab-level operations the `WindowController`
already calls.

### `TabController` responsibilities

- Owns `paneCanvas: PaneCanvasController` and up to three lazily-created auxiliary
  `TerminalSurface`s (bottom/right drawer, lazygit), each created via the shared
  `TerminalSurfaceFactory` (not the pane registry — these are singletons, not tree
  leaves).
- `view` — an `NSView` laying out the pane canvas with the drawers docked to its
  bottom/right edges (fixed sizes, shown/hidden by toggle), and the lazygit float
  overlaid centered with a dimmed backdrop.
- Overlay open flags: `isBottomOpen`, `isRightOpen`, `isLazygitOpen` (plain Bools —
  static sizes mean no sizing model to test).
- Toggle methods: `toggleBottom()`, `toggleRight()`, `toggleLazygit()` — create the
  surface on first open (login-shell, cwd = `paneCanvas.focusedCWD`), otherwise
  show/hide the retained view.
- Forwards to `paneCanvas`: `start()`, `split(_:)`, `navigate(_:)`,
  `closeFocused()`, `focusActivePane()`, `title`, `focusedCWD`, `onTitleChanged`,
  `onLastPaneClosed`, and copy/paste (routed to whichever surface is focused — a
  pane OR an open drawer/lazygit).
- `shutdown()` — terminates the pane canvas **and** every auxiliary surface (no
  leaked drawer shells on tab close).
- **Owns zoom orchestration** (`⌘F`): a `zoomTarget` of `.pane` / `.bottomDrawer` /
  `.rightDrawer` (or nil). When zoomed it shows only the target surface filling the
  tab region and hides everything else; for a pane target it asks `paneCanvas` to
  render just that leaf. Restoring returns to the prior drawer-open layout.
- Exposes overlay state so the toggle dock can render the active tab's indicators,
  and an `onOverlayStateChanged` signal so the dock refreshes when a toggle fires.

### `WindowController` changes (PR1)

- Holds `[TabID: TabController]` instead of `[TabID: PaneCanvasController]`; mounts
  `tabController.view`; all existing tab machinery (mount/swap, `⌘w` cascade,
  titles, `activeController`) forwards through `TabController` to its
  `paneCanvas`. Behavior for existing tab/pane features is unchanged.
- Gains the **global left sidebar** (PR4) and hosts the **toggle dock** (PR3) in
  the tab-bar row.
- Routes new chords to the active `TabController`: `⌘B`/`⌘|`/`⌘G` → drawer/lazygit
  toggles; `⌘E` → its own global sidebar toggle.

## Components (new files, `Sources/ZenTerm/`)

- `TabController.swift` — the per-tab wrapper above. [PR1]
- `DrawerView.swift` — a docked, fixed-size container hosting one drawer surface at
  a given edge (`.bottom` / `.right`), with a subtle divider; shown/hidden by
  toggle. Reused for both drawers. [PR1]
- `LazygitOverlay.swift` — centered float + dimmed backdrop hosting the lazygit
  surface; Escape / backdrop-click / process-exit dismiss. [PR3]
- `ToggleDock.swift` — the global bottom-right button row (split-v/-h, sidebar,
  bottom, right, lazygit) with active/inactive styling reflecting the active tab.
  [PR4]
- `SidebarView.swift` — the global left panel shell (minimal; Epic-4 content). [PR5]

Zoom (PR2) adds no new file: `PaneCanvasController` gains a `zoom(_ leaf:)` /
`unzoom()` that renders a single leaf full-canvas (surface retained, no restart),
`TabController` gains the `zoomTarget` orchestration + `⌘F` handling, and the zoom
indicator is a small iris corner badge on `PaneHostView` / `DrawerView` (an
`isZoomed` flag).

## Behavior details

### Drawer lifecycle
1. `⌘B` / `⌘|` with the drawer closed → create the surface (login shell, cwd =
   focused pane's live cwd), start it, show `DrawerView` docked at its edge, focus it.
2. Same chord with the drawer open → hide the `DrawerView`; the surface + process
   **stay alive** (retained by `TabController`). Reopen → re-show the same surface
   with its accumulated output.
3. Switching tabs detaches the whole `TabController.view` (retained) → drawer
   processes keep running.
4. Closing the tab → `TabController.shutdown()` terminates the pane canvas and all
   auxiliary surfaces.

### lazygit float
- `⌘G` with no float → create a surface launched as `lazygit` **via a login shell**
  (`$SHELL -l -c lazygit`, matching Epic 0's login-shell PATH fix so a
  Homebrew-installed `lazygit` resolves), cwd = focused pane's cwd; show it centered
  over the tab with a dimmed backdrop; focus it.
- Dismiss on **Escape**, **backdrop click**, or **process exit** (`surfaceDidExit`):
  remove the float and terminate/clear the surface. `⌘G` again launches a fresh
  lazygit.
- The float is per tab; switching tabs hides it with the tab (its state is the
  tab's own).

### Zoom (`⌘F`)
- `⌘F` zooms the **focused terminal** — a pane leaf OR an open drawer — to fill the
  entire tab region, as if it were the tab's only terminal. `TabController` tracks
  which surface kind is focused (updated on pane/drawer focus) to pick the target.
- While zoomed, everything else in the tab region is hidden: for a **pane** target,
  `paneCanvas` renders just that leaf (surface retained — no shell restart) and the
  drawers are hidden; for a **drawer** target, the drawer surface fills the region
  and the pane canvas + other drawer are hidden.
- A **zoom indicator** (a small iris corner badge) marks the zoomed surface.
- `⌘F` again **or Escape** restores the prior layout (including whichever drawers
  were open). Zoom is per-tab transient state (not persisted); switching tabs leaves
  each tab's zoom as it was.
- The lazygit float is independent of zoom (it's already a full-tab overlay).

### Toggle dock (global, mirrors active tab)
- One dock in the tab-bar row: tab bar left, dock right.
- Buttons: split-vertical, split-horizontal | sidebar (⌘E) | bottom (⌘B) | right
  (⌘|) | lazygit (⌘G). Active buttons use the iris accent; the sidebar button
  reflects the window's global state, the drawer/lazygit buttons reflect the
  **active tab's** state and update on tab switch (via `TabController.onOverlayStateChanged`
  and on `select`).
- Clicks invoke the same actions as the chords, on the active tab / window.

### Global left sidebar
- Per-window toggleable panel to the left of the tab region, spanning all tabs.
  `⌘E` toggles. Minimal styled shell (heading + placeholder sections) — real
  content lands with the Epic 4 workspace model.

### Keybinds (via `KeyInterceptor`)
| Chord | Action | Scope |
|-------|--------|-------|
| `⌘B` | toggle bottom drawer | active tab |
| `⌘|` (`⌘⇧\`) | toggle right drawer | active tab |
| `⌘G` | toggle lazygit float | active tab |
| `⌘F` | toggle zoom of the focused terminal | active tab |
| `⌘E` | toggle left sidebar | window (global) |

`⌘\` remains vertical-split (Epic 1); `⌘|` is its shifted sibling. `KeyInterceptor`
today only intercepts **bare-`⌘`** chords — it grows to also intercept this one
`⌘⇧\` chord (like the menu's `⌘⇧H`). All other un-reserved chords still pass
through to the PTY. Drawers/panes/lazygit remain click-to-focus.

## Out of scope

- Drawer drag-resize / size persistence (static sizes this epic).
- Sidebar content / workspace model (Epic 4).
- Command palette, toasts (Epic 4).
- Splitting inside a drawer (drawers are single terminals).

## Definition of done

- `⌘B` / `⌘|` open a per-tab drawer hosting a live login shell in the focused
  pane's cwd; toggling hidden keeps its process running; switching tabs preserves
  each tab's drawers; closing a tab terminates its drawer shells (no zombies).
- `⌘F` zooms the focused pane or drawer to fill the tab (surface retained, no
  restart) with a zoom indicator; `⌘F` again or Escape restores the prior layout.
- `⌘G` opens a per-tab lazygit float running `lazygit` in the right cwd; Escape /
  backdrop / quitting lazygit all dismiss it cleanly.
- The toggle dock mirrors the active tab's overlay state and toggles each overlay.
- `⌘E` toggles a global left sidebar.
- Seam intact (chrome imports `TerminalKit`/`PaneKit`/`TabKit` + AppKit only; no
  SwiftTerm above the seam). `swift build` clean and `swift test` green.

## PR breakdown (PR-sized Linear tickets under one Epic 3 project)

1. **`TabController` refactor + bottom & right drawers** (`⌘B` / `⌘|`) — the
   per-tab wrapper, `WindowController` refactor to hold `TabController`s, drawer
   lifecycle (persistent, cwd-inherited, terminate-on-tab-close), `DrawerView`,
   fixed sizes. The load-bearing refactor.
2. **Zoom** (`⌘F`) — `PaneCanvasController` single-leaf render + `TabController`
   `zoomTarget` orchestration (hide siblings), focus-kind tracking, Escape-to-exit,
   the zoom corner indicator.
3. **lazygit float** (`⌘G`) — `LazygitOverlay`, per-tab, login-shell launch,
   auto-close on exit, Escape/backdrop dismiss.
4. **Toggle dock** — global bottom-right widget, mirrors active tab, split +
   toggle buttons.
5. **Global left sidebar** (`⌘E`) — minimal per-window panel shell. Last.
