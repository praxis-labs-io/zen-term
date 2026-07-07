# Epic 2 — Tabs + windows

**Status:** Approved (design)
**Date:** 2026-07-06
**Linear project:** Epic 2 — Tabs + windows (`41569099-91ac-4936-94df-1816ff7d8d35`)
**Depends on:** Epic 1 (pane canvas + splits + halo)

## Goal

Become a full daily-driver surface — the point where zen-term replaces kitty.
Wrap Epic 1's per-window pane tree in an in-window numbered tab bar, and add real
multi-window. Each tab owns its own pane tree and focus; background-tab shells
keep running when their tab is inactive.

## Core insight — the per-tab unit already exists

Epic 1 carved `PaneCanvasController` as the unit that owns a pane tree, a surface
registry, per-leaf cwd, focus, and a single `canvasView`. That is exactly a
**tab**. Epic 2 does not touch `PaneKit` or the seam. It:

1. Adds a **pure tab model** (`TabKit`) for the ordering/active-index bookkeeping.
2. Multiplies `PaneCanvasController` — one per tab — behind a `WindowController`
   that swaps which tab's `canvasView` is mounted and renders the tab bar.
3. Multiplies `WindowController` — one per window — behind an `AppDelegate` that
   manages the window set and routes chords to the key window.

```
AppDelegate (window manager)
 └── [WindowController]                    ← one per NSWindow, independent tab set
      ├── HostWindow (tabbingMode=.disallowed)
      ├── TabBarView                        ← numbered bottom-left bar
      ├── TabList (from TabKit)             ← pure: [TabID] + activeIndex
      └── [TabID : PaneCanvasController]    ← one controller per tab (Epic 1 unit)
```

## Architecture

### New target: `TabKit` (pure, tested)

Mirrors `PaneKit`'s role: pure Swift, **no AppKit, no SwiftTerm**, fully
unit-tested. Holds the tab bookkeeping whose edge cases (which tab becomes active
after the active one closes) are exactly the off-by-one-prone logic worth testing
in isolation — the same reasoning that isolated `PaneTreeOps` from the AppKit
layer.

- `TabID` — `struct TabID: Hashable` wrapping an `Int` (same shape as `PaneID`).
- `TabList` — value type owning `private(set) var order: [TabID]` and
  `private(set) var activeIndex: Int`, with:
  - `var activeID: TabID` — `order[activeIndex]`.
  - `mutating func add(_ id: TabID)` — appends and makes the new tab active.
  - `mutating func select(_ id: TabID)` — makes `id` active if present (no-op
    otherwise); also `select(index:)` clamped to range.
  - `mutating func close(_ id: TabID) -> Bool` — removes `id`; returns `false`
    when it was the **last** tab (list now empty → caller closes the window),
    `true` otherwise. When the closed tab was active, the neighbor to its right
    becomes active (or the new last tab if it was rightmost) — never leaves
    `activeIndex` out of range.
  - `init(first: TabID)` — one tab, active.

`TabList` never owns AppKit objects; `WindowController` keeps a parallel
`[TabID: PaneCanvasController]` dict keyed by id (no positional desync — order and
active live only in `TabList`).

### New chrome files (`Sources/ZenTerm/`)

- `Tab.swift` — thin per-tab record the chrome needs beyond the controller:
  `TabID` + a cached `title` string. (The controller is held in the
  `WindowController`'s dict, not here, to keep this a value.)
- `TabBarView.swift` — `NSView` rendering the prototype's bottom-left numbered
  bar: `1 title · 2 title · …`, mono 11pt, iris underline under the active tab,
  a `+` new-tab affordance. Click a tab → select; middle-click or the hover `×`
  → close. Pure view: takes a snapshot (`[(index, title, isActive)]`) + callbacks
  (`onSelect(TabID)`, `onClose(TabID)`, `onNewTab`); owns no model state.
- `WindowController.swift` — owns one `HostWindow`, a `TabList`, the
  `[TabID: PaneCanvasController]` dict, and a `TabBarView`. Lays out the active
  tab's `canvasView` filling the content above a fixed-height tab-bar strip
  pinned to the bottom. Drives new/close/select-tab, the `⌘w` cascade, and cwd
  inheritance. Rebuilds the tab bar's snapshot whenever tabs or titles change.

### Refactored files

- `AppDelegate.swift` — from single-window owner to **window manager**: owns
  `[WindowController]`, creates the first window on launch, handles `⌘n`
  (new window), hosts the **single** global `KeyInterceptor`, and routes each
  reserved chord to `NSApp.keyWindow`'s `WindowController`. One monitor total —
  never one per window (multiple local monitors all fire per event → double
  handling).
- `KeyInterceptor.swift` — extend `ReservedChord` with `.newTab` (`⌘t`),
  `.selectTab(Int)` (`⌘1`–`⌘9`), `.newWindow` (`⌘n`). `.closePane` (`⌘w`) stays.
  All remain bare-`⌘` chords (existing `flags == .command` guard unchanged).
- `HostWindow.swift` — add `tabbingMode = .disallowed` (kills native macOS
  tabbing / window merging, which multi-window + yabai require).
- `PaneCanvasController.swift` — two small additions, no behavior change to
  existing panes:
  - `init(initialCWD: URL?)` — seeds the first pane's cwd (for new-tab /
    new-window inheritance). Existing default remains `nil` → login shell default.
  - `var title: String` (computed: focused leaf's cwd basename, fallback `~`) and
    `var onTitleChanged: (() -> Void)?`, fired when the focused pane's cwd changes
    or focus moves between panes. Uses the cwd already tracked in `cwdByLeaf` — no
    seam change.
  - Existing `onLastPaneClosed` is repurposed by the `WindowController` to mean
    "the last pane in this tab exited → close this tab."

## Behavior

### Keybinds

| Chord | Action |
|-------|--------|
| `⌘t` | New tab (inherits focused pane's cwd), becomes active |
| `⌘1`–`⌘9` | Select tab N (no-op if N > tab count) |
| `⌘n` | New window (inherits focused pane's cwd), one fresh tab |
| `⌘w` | Close cascade (see below) |

Epic 1 chords are unchanged: `⌘\` / `⌘-` split, `⌘h/j/k/l` nav, click-to-focus.
Un-reserved chords still pass through to the PTY (the Ctrl+hjkl / nvim rule holds).

### The `⌘w` cascade

`⌘w` closes the **focused pane**. When that was the tab's last pane, the **tab**
closes. When that was the window's last tab, the **window** closes. When that was
the last window, the app quits (already wired via
`applicationShouldTerminateAfterLastWindowClosed`). A shell exiting on its own
(not `⌘w`) follows the same cascade via `PaneCanvasController`'s exit handling →
`onLastPaneClosed` → close tab → …

### Tab switching — detach / reattach

Switching tabs removes the outgoing tab's `canvasView` from the window's view
hierarchy and mounts the incoming tab's `canvasView`. The outgoing
`PaneCanvasController` (and its registry, surfaces, PTYs) is **retained** by the
`WindowController`'s dict, so **its shell keeps running while detached** — the PTY
and child process are independent of view attachment; the terminal emulator
buffers output and shows current state on reattach. On switch, the incoming tab
restores focus + halo to its own focused pane.

### cwd inheritance

New tab inherits the **current tab's** focused-pane cwd. New window inherits the
**key window's** focused-pane cwd. One rule, consistent with Epic 1's
"new panes inherit the focused pane's cwd."

### Tab titles

A tab's title is its focused pane's **cwd basename** (fallback `~`). It updates
live via `onTitleChanged`. Richer OSC-title following is out of scope (it would
require a seam addition).

### Multi-window

`⌘n` creates a new `HostWindow` + `WindowController` with one fresh tab, offset
from the key window, made key. Each window has a fully independent tab set. With
`tabbingMode = .disallowed`, macOS never merges these into native tabs, so a
tiling WM (yabai) manages them as ordinary windows.

## Out of scope

- Drawers, command palette, workspace model (later epics).
- OSC-title-driven tab titles (cwd basename only for v1).
- Window-state restoration across relaunch.
- Tab reordering / drag.

## Definition of done

- Tabs create (`⌘t`), close (`⌘w` cascade + `×`/middle-click), and switch
  (`⌘1`–`⌘9`, click) with **each tab's pane tree and focus preserved**.
- **Background-tab shells keep running when their tab is inactive** (view
  detached, process alive) — verified by starting a long-running command
  (e.g. `ping`) in tab 1, switching away and back, and seeing accumulated output.
- Native tabbing is disabled (no macOS tab bar, no window merging).
- `⌘n` opens an independent window; multi-window behaves under yabai.
- `swift build` clean and `swift test` green (new `TabKit` tests included).

## PR breakdown (PR-sized Linear tickets)

1. **TabKit + pure tab model** — new `TabKit` target, `TabID`, `TabList`, unit
   tests. No chrome wiring. Independently mergeable.
2. **In-window tabs** — `WindowController`, `TabBarView`, `Tab`, view-swap,
   `⌘t` / `⌘1`–`⌘9`, `⌘w` cascade, cwd inheritance, titles.
   `PaneCanvasController` additions. Single-window (multi-window still stubbed to
   one window). Independently mergeable and demoable.
3. **Multi-window + disable native tabbing** — `AppDelegate` window manager,
   `⌘n`, chord routing to key window, `tabbingMode = .disallowed`.
