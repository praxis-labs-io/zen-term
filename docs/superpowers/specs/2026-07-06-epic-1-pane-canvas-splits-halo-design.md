# Epic 1 — Pane Canvas + Splits + Halo — Design

> Detailed design for Epic 1. Extends the charter in
> [`2026-07-06-chrome-architecture-design.md`](./2026-07-06-chrome-architecture-design.md)
> (§ "Epic 1 — Pane canvas + splits + halo"). Feeds the implementation plan in
> `docs/superpowers/plans/`.

## Goal

Put zen-term's signature look and split-based workflow on top of Epic 0's proven
`TerminalSurface`. End state: a **daily-drivable, splits-only terminal** — create,
close, and navigate splits, each a real independent shell, with the iris focus
halo always marking the focused pane, and splitting/closing never orphaning a
running process.

## Scope

**In.** Split create (vertical / horizontal); split close; spatial pane
navigation; focus routing; the focus halo; the floating-pane canvas styling
(generalized from Epic 0's single pane); the recursive host layer that wraps each
`surface.view` and draws the frame + halo; zen-term's first `NSMenu`; the
extended reserved-chord set.

**Out (later epics).** Drag / keyboard split resize (fixed ratio only — deferred);
tabs (Epic 2); drawers + lazygit float (Epic 3); command palette (Epic 4).

**Depends on.** Epic 0 — `TerminalSurface` seam, `TerminalSurfaceFactory.make()`,
`SwiftTermSurface`, selective `KeyInterceptor`, delegate events (title / cwd /
exit).

## Locked decisions (from brainstorm)

| Decision | Choice |
| --- | --- |
| Split-tree architecture | **Immutable value tree + stable surface registry** (Approach A) |
| Pure logic home | New **`PaneKit`** library target (no backend deps), fully TDD'd |
| Halo | Iris accent **border + soft outer glow**, tracking one `focusedLeafID` |
| Vertical split | `⌘\` |
| Horizontal split | `⌘-` |
| Pane navigation | `⌘h` / `⌘j` / `⌘k` / `⌘l` (spatial nearest-neighbor) |
| Close pane | `⌘W`; closing the **last** pane closes the window |
| `⌘H` conflict | zen-term owns its main menu and does **not** bind `⌘H` to Hide; Hide moves to `⌘⇧H`, freeing `⌘H` for nav-left |
| New-pane cwd | **Inherit** the focused pane's cwd (via Epic 0's OSC 7 tracking) |
| Minimum split size | Refuse a split when the pane is under **~240pt** on the split axis |

Keybinds remain **provisional** (a dedicated rework pass comes later); this set is
what Epic 1 implements.

## Module structure

A new pure library target isolates the testable chrome logic:

```text
TerminalKit  (Epic 0)  — the seam + SwiftTerm backend (only SwiftTerm consumer)
PaneKit      (NEW)     — pane-tree model, spatial nav, reconcile-diff, and the surface
                         registry. Depends on TerminalKit (for the TerminalSurface seam
                         type) — NOT on SwiftTerm. AppKit only for CoreGraphics types.
ZenTerm      (Epic 0)  — the AppKit chrome (views/menu/keybinds). Depends on PaneKit + TerminalKit.
```

`ZenTerm` uses `main.swift` (top-level executable code), which cannot be cleanly
`@testable`-imported — so the DoD-critical logic (tree ops, nav, reconcile-diff,
and the surface registry) lives in `PaneKit`, which gets its own `PaneKitTests`.
The registry takes an **injected surface factory** (`() -> TerminalSurface`) so
tests drive it with a fake; `ZenTerm` passes `TerminalSurfaceFactory.make`.

**Seam unchanged:** `PaneKit` depends on `TerminalKit` for the `TerminalSurface`
protocol only. SwiftTerm is not a *direct* dependency of `PaneKit`, so `PaneKit`
cannot `import SwiftTerm` — only `TerminalKit` imports the backend, and `ZenTerm`
still imports no backend.

## Components

### 1. Pane model (`PaneKit`, pure, TDD'd)

A value-type port of the prototype's `PaneNode`:

```swift
public enum SplitAxis { case vertical, horizontal }

public indirect enum PaneNode {
    case leaf(id: PaneID)
    case split(id: SplitID, axis: SplitAxis, ratio: Double, a: PaneNode, b: PaneNode)
}
```

`PaneID` / `SplitID` are distinct value types (e.g. wrappers over a monotonically
increasing counter injected by the caller — no global mutable state inside
`PaneKit`, so tree ops stay pure and deterministic under test).

A `PaneTree` value wraps the state a single window needs:

```swift
public struct PaneTree {
    public var root: PaneNode
    public var focusedLeaf: PaneID
}
```

Pure operations (each returns a new `PaneTree`/`PaneNode`, ported from the
prototype's reducer functions):

- `split(_ tree:, at leaf:, axis:, newLeaf:) -> PaneTree` — replaces the target
  leaf with a split of `[oldLeaf, newLeaf]` at ratio `0.5`; focus moves to the new
  leaf. Callers supply the new ids (determinism).
- `close(_ tree:, leaf:) -> PaneTree?` — removes the leaf; **collapses the parent
  split and promotes the sibling**; focus moves to the sibling's first leaf.
  Returns `nil` when closing the only remaining leaf (the window should close).
- `firstLeaf(_ node:) -> PaneID`
- `leafIDs(_ node:) -> [PaneID]`
- `setRatio(_ tree:, split:, ratio:) -> PaneTree` (used internally; no UI resize
  in Epic 1, but the op exists for the reconciler/tests and Epic-2+ resize).

### 2. Spatial navigation (`PaneKit`, pure, TDD'd)

Ported from the prototype's geometric nearest-neighbor:

```swift
public enum Direction { case left, right, up, down }

/// Given the focused leaf's frame and the candidate leaves' frames (in one
/// coordinate space), returns the id of the nearest neighbor in `direction`,
/// or nil if none lies that way.
public func nearestLeaf(from: PaneID,
                        frames: [PaneID: CGRect],
                        direction: Direction) -> PaneID?
```

Scoring matches the prototype: candidates must lie in the requested direction
(center-delta sign check with a small deadzone); score = `primaryDistance +
2 × perpendicularOffset`; lowest score wins. Frames come from the rendered pane
views but the scoring is pure `CGRect` math — unit-tested with hand-built frame
maps.

### 3. Surface registry + reconciler (`PaneKit`, TDD'd)

The DoD-critical part: **a leaf's running shell survives tree restructures.**

- **Reconcile-diff (pure, `PaneKit`):** given the previous and next `leafIDs`,
  returns `(created: [PaneID], removed: [PaneID], retained: [PaneID])`. Pure set
  logic.
- **`PaneSurfaceRegistry` (`PaneKit`):** owns `[PaneID: TerminalSurface]` and an
  injected `makeSurface: () -> TerminalSurface`. Applies a diff: **create** (via
  the injected factory) only for `created` ids; **terminate** only for `removed`
  ids; **retain** (do nothing to) the rest. Reused surfaces keep their shell,
  scrollback, and first-responder state — their views are re-parented, never
  recreated. `ZenTerm` constructs it with `makeSurface: TerminalSurfaceFactory.make`;
  `PaneKitTests` constructs it with a fake surface to assert instance identity.

New-pane `TerminalSurfaceConfig` carries `workingDirectory =` the focused pane's
last-known cwd. The chrome tracks per-leaf cwd from the Epic 0
`surface(_:cwdDidChange:)` delegate; on split it reads the focused leaf's latest
cwd and seeds the new surface with it (falls back to default when unknown).

### 4. View tree (`ZenTerm`, AppKit)

- **`SplitContainerView: NSView`** — recursive. For a `.split` node, lays out its
  two child containers along the axis with the gutter and the fixed ratio (Auto
  Layout or manual `layout()`); a `.leaf` renders a `PaneHostView`. No drag
  handle (fixed ratio). Generalizes Epic 0's single-pane layout.
- **`PaneHostView`** (generalized from Epic 0) — hosts one leaf's `surface.view`,
  draws the rounded/bordered frame over the canvas, and renders the **halo** when
  its leaf is focused.

On a tree change, `ZenTerm` rebuilds the `SplitContainerView` hierarchy but pulls
each leaf's **existing** surface view from the registry (per §3) — so layout is
cheap and shells are never recreated.

### 5. Focus routing (`ZenTerm`)

- One `focusedLeafID` (mirrors `PaneTree.focusedLeaf`).
- Setting focus → `window.makeFirstResponder(surface.view)` for that leaf's
  surface. Only one pane is first responder at a time → no focus contention among
  the multiple `LocalProcessTerminalView`s.
- **Click-to-focus:** clicking a pane focuses its leaf (the host view routes the
  mouse-down to a focus callback; the surface then becomes first responder).
- **Keyboard nav:** `⌘hjkl` → `nearestLeaf(...)` over the current pane frames →
  focus the result.
- The halo re-renders on focus change (old pane loses it, new pane gains it).

### 6. Halo (`ZenTerm`, `PaneHostView`)

Matches the prototype: the focused pane draws an **iris accent inset border**
(`--iris` `#c4a7e7`, ~1pt) **and** a **soft outer glow** (layer shadow: iris
color, low opacity, modest blur, zero offset). Unfocused panes keep the subtle
Epic 0 panel border (`NSColor(white: 1, alpha: 0.08)`). The pulsing accent cursor
from the prototype is a terminal-content concern (SwiftTerm renders the cursor) —
out of scope for the chrome halo.

### 7. Menu + keybinds (`ZenTerm`)

- **Main menu:** install zen-term's first `NSMenu` on `applicationDidFinishLaunching`
  — an application menu (About, Hide on **`⌘⇧H`**, Quit on `⌘Q`) and an Edit menu
  (Copy `⌘C` / Paste `⌘V` routed to the focused surface). `⌘H` is deliberately
  **not** bound, freeing it for nav-left.
- **Extend `KeyInterceptor`** reserved allowlist to route to pane ops:
  `⌘\` → split vertical, `⌘-` → split horizontal, `⌘h/j/k/l` → navigate,
  `⌘W` → close focused pane (last pane → close window). `⌘` chords never reach the
  PTY, so `Ctrl+hjkl` still passes through untouched to nvim. `⌘\` matches on the
  produced character (`\`), and `⌘-` on `-`.

## Data flow

```text
key / click ─▶ KeyInterceptor / host view
            ─▶ intent (split axis | close | navigate dir | focus leaf)
            ─▶ PaneKit pure op ⇒ new PaneTree  (+ reconcile-diff)
            ─▶ PaneSurfaceRegistry.apply(diff)   (create/terminate/retain shells)
            ─▶ ZenTerm rebuilds SplitContainerView from new tree + registry views
            ─▶ focus routing: makeFirstResponder(focused leaf) + halo update
```

The `PaneTree` value is the single source of truth for layout + focus; the
registry is the single source of truth for live shells; views are derived from
both and hold no independent state.

## Error / edge handling

- **Split refused** when the focused pane is under ~240pt on the split axis — the
  op is a no-op (optionally a subtle bell/flash; no error dialog).
- **Close last pane** → `close` returns `nil` → the chrome closes the window
  (which quits via `applicationShouldTerminateAfterLastWindowClosed`, matching
  Epic 0).
- **Shell exits on its own** (Epic 0 `surfaceDidExit`) → treat as closing that
  leaf: run the same `close` path (promote sibling / close window if last).
- **cwd unknown at split** → new surface starts with the default working
  directory (login shell at home).

## Testing strategy

- **`PaneKitTests` (XCTest):** `split` / `close` (including sibling-promotion and
  last-leaf → nil), `firstLeaf`, `leafIDs`, `setRatio`, reconcile-diff
  (created/removed/retained sets), and `nearestLeaf` scoring across hand-built
  frame maps (left/right/up/down, ties, nothing-in-direction). This is the
  DoD-critical logic and it is all pure.
- **Registry identity:** unit-test `PaneSurfaceRegistry.apply(diff)` with a fake
  `TerminalSurface` (via the seam) asserting a retained id keeps the **same
  instance** across a split and a close (no recreate, no orphaned terminate).
- **GUI (manual runbook):** split V/H, navigate all directions, click-to-focus,
  halo tracks focus, close pane promotes sibling, close last pane closes window,
  every pane is an independent live shell, split refused when too small, new pane
  inherits cwd.

## Definition of Done

- Create, close, and navigate splits (V + H) with focus routing correct across
  all panes; `⌘hjkl` moves spatially; click focuses.
- The halo always marks exactly the focused pane.
- Every pane is an independent live shell built via `TerminalSurfaceFactory.make()`.
- Splitting / closing **never orphans a running process** and never recreates an
  existing pane's shell (registry identity holds).
- Closing the last pane closes the window; single-pane behavior matches Epic 0.
- New panes inherit the focused pane's cwd; splits under ~240pt are refused.
- Visually matches the prototype (canvas, rounded panes, gutters, iris halo).
- `swift build` clean; `PaneKitTests` + `TerminalKitTests` green; seam intact
  (`ZenTerm` imports no backend).

## Open questions

- None blocking. The keybind set is provisional (dedicated rework later). The
  `⌘J` nav-down chord will collide with the Epic 3 drawer-toggle; resolved when
  drawers land.
