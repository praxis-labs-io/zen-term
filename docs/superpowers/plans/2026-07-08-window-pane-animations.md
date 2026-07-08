# Window & Pane Movement Animations — Implementation Plan

> **Status:** planning handoff. No code written yet (this session ran on Linux with no
> Swift toolchain — cannot build/run/verify). This doc is written so another agent on a
> Mac can pick it up and implement + verify.
>
> **Linear:** ticket lives in the **Niceties** project, **ZenTerm** team (created by
> hand — Linear MCP was unreachable from the web session). Reference its id in commits.
>
> **Branch:** implement on `claude/window-pane-animations-tvtwfs` (the designated feature
> branch). This planning commit is pushed separately as `motion-plan`.

## Goal

Add subtle, **snappy** motion to every window/pane movement in the chrome. There is
currently **zero animation code** in the app — every show/hide/move is instantaneous
(constraint activate/deactivate, `addSubview`/`removeFromSuperview`, or direct CALayer
property assignment). We add one shared motion layer and wire it through the existing
(already centralized) presentation choke points.

Surfaces in scope:

- **Drawers** — bottom (`⌘B`) / right (`⌘|`) open & close
- **Splits** — a new pane appearing
- **Pane close** — sibling reclaiming the space
- **Zoom** (`⌘F`) — pane/drawer filling the tab and back
- **Lazygit float** (`⌘G`) — open & close
- **Command palette** (`⌘P`) — open & close
- **Project / repo picker** (`⌘⇧P`) — open & close
- **Tab switch** — between tab canvases
- **New tab** — first mount of a fresh canvas
- **Focus halo** — animated fade on focus change **and** a subtle crossfade as focus
  navigates between panes (`⌘hjkl`), plus the related icon-button / tab-chip tint snaps

## Decisions (locked with the user)

| Decision | Choice |
|---|---|
| Motion character | **Snappy spring** — slight overshoot, ~0.24s settle |
| Overlay entrance (palette / picker / float) | **Fade + subtle scale** (0.97 → 1.0) |
| Drawer motion | **Slide in from the docked edge**; canvas reflows to meet it |
| Extra scope | Zoom, pane-close, tab-switch, new-tab — **all in** |
| Halo | **Folded in** — animated halo fade + focus-nav crossfade, kept **very snappy** |

## Motion language — two speeds

One shared `Sources/ZenTerm/Motion.swift` namespace owns all timing so the whole app
feels like one system.

- **Structural = snappy spring** (~0.24s, slight overshoot). Panels/cards appearing,
  drawer slides, new-pane / new-tab entrances. `CASpringAnimation`, roughly
  `mass 1 / stiffness ~340 / damping ~26` (underdamped ≈ 0.7 ratio → gentle overshoot).
  **Tune live on a Mac.**
- **Halo / tint = fast ease** (~0.12s, `easeOut`). Deliberately faster than structural so
  it never lags behind rapid `⌘hjkl` focus nav.
- **Region crossfade** (~0.16s) for zoom / tab-switch dissolves.

`Motion` exposes a handful of primitives and **honors Reduce Motion globally**
(`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` → every primitive collapses
to an instant apply of the final state, no animation).

Proposed primitive surface (final names at implementer's discretion):

- `springScaleFade(_ view: NSView, appearing: Bool, completion: (() -> Void)? = nil)`
  — opacity 0↔1 + scale 0.97↔1.0 about the view's center. Overlays, new pane, new tab.
- `slide(_ view: NSView, fromEdge:, distance:, appearing:, completion:)`
  — spring-translate a full-size panel in/out from a docked edge. Drawers.
- `fade(_ view: NSView, to: Float, duration:, completion:)`
  — opacity ramp. Zoom sibling fades, tab-switch crossfade.
- `ease(_ layer: CALayer, _ keyPath: String, from:, to:, duration: haloDuration)`
  — explicit CABasicAnimation for a single layer property (halo border/shadow, tint bg).

## Load-bearing principle: animate appearance/disappearance, let geometry reflow

Terminals are **reflowing text, not scalable images** — geometrically tweening a pane's
size (scale transform) stretches glyphs and looks bad. An instant reflow, by contrast,
already feels fine (it's what a live window-resize drag does). So:

- The eye-catching part — a card scaling up, a pane popping in, a drawer sliding in —
  gets the spring.
- Size changes underneath just settle to their final layout.

**Corollary: every transition uses live views — no bitmap snapshots.** Snapshotting a
SwiftTerm surface is unreliable (may be blank), so we avoid it entirely:

- **Tab switch:** mount the incoming tab over the outgoing, fade the incoming in, then
  remove the outgoing. Both are real, live views.
- **Zoom:** fade the non-focused hosts out, *then* rebuild to the single leaf; on unzoom,
  rebuild to all with siblings at opacity 0 and fade them in.
- **Pane close:** animate the closing pane's host out *before* mutating the tree.
- **Split:** mutate + rebuild, then fade+scale in only the newly-created leaf's host.

## Per-surface plan

| Surface | File(s) & insertion point | Technique |
|---|---|---|
| Command palette | `WindowController.toggleCommandPalette` / `closeCommandPalette`; `PaletteOverlay` | Card `springScaleFade`; route dismiss through an `animateOut { removeFromSuperview }` |
| Project picker | `WindowController.toggleRepoPicker` / `closeRepoPicker`; shared `PaletteOverlay` base | Same as palette — one implementation on the base class covers both |
| Lazygit float | `TabController.toggleLazygit` / `closeLazygit`; `LazygitOverlay` | Card `springScaleFade` **and** fade its dim backdrop |
| Bottom / right drawer | `TabController.toggleBottomDrawer` / `toggleRightDrawer` / `relayoutPanels` | `slide` the full-size panel from its edge; canvas reflows (see drawer note) |
| Split | `PaneCanvasController.split` → `rebuildViews` | New leaf's host `springScaleFade(appearing:)`; siblings reflow instantly |
| Pane close | `PaneCanvasController.closeFocused` / delegate exit | `springScaleFade(appearing:false)` on the closing host, then mutate on completion |
| Zoom | `TabController.toggleZoom` / `exitZoom`; `PaneCanvasController.zoom/unzoom` | Fade non-focused hosts out → rebuild to single; reverse on unzoom |
| Tab switch | `WindowController.mountActive` | Mount incoming over outgoing, `fade` incoming 0→1, remove outgoing on completion |
| New tab | `WindowController.mountActive` (first mount of a fresh tab) | Canvas `springScaleFade(appearing:)` |
| Focus halo | `PanelHostView.updateHalo` (drives pane **and** drawer halos) | `ease` `borderColor` / `shadowOpacity` / `shadowRadius`; nav crossfade falls out (losing host eases out while gaining host eases in) |
| Icon-button / tab-chip tint | `IconButton.update`, `TabBarView.Chip.updateBackground` | `ease` the layer `backgroundColor` (icon `contentTintColor` may stay instant — barely visible) |

## Key implementation notes

- **Drawer PTY safety (hard constraint).** An attached drawer must never be laid out at
  0×0 — a 0-width drawer resizes its PTY to 0 columns and crashes size-sensitive TUIs
  (see the existing `setAttached` comment in `TabController`). So the drawer **slides via a
  layer transform at full size** (never animate its width/height constant from ~0). On
  **close**, keep the panel attached & full-size for the whole slide-out and only
  `setAttached(false)` in the completion block.
- **Drawer canvas reflow.** The user chose "canvas reflows to meet it." Apply the open/
  close tile constraints and wrap the `layoutSubtreeIfNeeded()` in an
  `NSAnimationContext` (duration ~0.24s, `easeOut`) so the canvas glides; the drawer
  itself slides via spring transform on top. The panes' PTYs resize during the ~0.24s —
  acceptable (identical cost to a window-resize drag). **Fallback if it feels janky:**
  apply final constraints instantly (canvas snaps to final size once) and let the drawer
  slide into the reserved gap — no per-frame pane resize. Implementer picks after seeing
  it move.
- **Overlay re-entrancy.** `⌘P` then `Esc` before the entrance settles must cancel cleanly.
  Guard with an `isDismissing` flag and reuse animation keys (adding an animation with the
  same key replaces the running one). Keep `focusSearchField()` immediate (don't wait for
  the animation).
- **Scale anchor.** `springScaleFade` scales about the view's center. For a layer-backed
  `NSView` the backing layer's `anchorPoint` is (0.5, 0.5), so a `transform.scale`
  animation is already center-anchored — but verify on the actual card view; if it scales
  from a corner, set `anchorPoint` (adjusting `position`) or scale a wrapper.
- **Halo animations need explicit CABasicAnimation.** Layer-backed `NSView`s disable
  implicit layer animations, so `updateHalo` must read the current (presentation) value,
  set the new model value, then add an explicit `ease` from old→new for `borderColor`,
  `shadowOpacity`, `shadowRadius`.
- **Seam intact.** All of this is chrome — `Sources/ZenTerm` only, AppKit + TerminalKit.
  Never `import SwiftTerm`.

## Tasks (each = one commit on the feature branch)

1. **Motion foundation** — `Motion.swift`: tuning constants, Reduce-Motion guard, and the
   primitives above. Add a small unit test where testable (e.g. Reduce-Motion path applies
   the final state and runs the completion synchronously; primitive input math). Most of it
   is AppKit-verified in later runbooks.
2. **Overlays** — palette, picker, lazygit float: `animateIn` / `animateOut(completion:)`
   on `PaletteOverlay` (covers palette + picker) and `LazygitOverlay`; route present/dismiss
   paths through them. Re-entrancy-safe.
3. **Drawers** — slide-in + canvas reflow; detach-after-close; focus handoff timing.
4. **Halo + tints** — animate `PanelHostView.updateHalo`; confirm the focus-nav crossfade;
   fold in the icon-button / tab-chip tint eases.
5. **Pane movements** — split entrance, pane-close exit, zoom sibling crossfade.
6. **Tab switch + new-tab** — mount-over-and-fade in `mountActive`.
7. **Tune & ship** — live-tune springs/durations on a Mac against the runbook below;
   verify Reduce Motion end-to-end; `scripts/check.sh` fully green; run `ship-feature`
   (`/code-review` → triage → Linear ticket → In Review).

## Verification (Mac only)

`scripts/check.sh` must be fully green (build → test → `swift-format --strict` →
`swiftlint --strict`). Animations have no unit coverage, so verify each by running
`swift run ZenTerm` and watching:

1. `⌘P` / `⌘⇧P` — card fades+scales in, and back out on `Esc` / backdrop click.
2. `⌘G` — lazygit float scales in with a fading dim backdrop; `⌘G` again dismisses; also
   verify auto-dismiss when lazygit exits on its own.
3. `⌘B` / `⌘|` — drawer slides in from its edge, canvas reflows; close slides out and the
   shell survives a hide→show (run `ping` in it, toggle, output accumulated).
4. Split — new pane pops in; existing panes reflow.
5. Close a split pane — closing pane eases out, sibling reclaims the space.
6. `⌘F` — zoom in/out; siblings crossfade; exact prior layout restored (incl. open drawers).
7. Tab switch (`⌘1/2`, clicks) — canvases crossfade; new tab (`⌘t`) fades+scales in.
8. `⌘hjkl` rapidly — halo glides between panes, never lags; single halo at all times.
9. System Settings → Accessibility → **Reduce Motion ON** — every transition is instant,
   nothing breaks, focus/PTY behavior unchanged.

## Risks / watch-items

- **Spring feel is unknowable without a Mac** — constants above are a starting point;
  expect a tuning pass (Task 7). Keep durations short; snappy over smooth.
- **Drawer reflow vs. reserved-space** — decide by eye (see drawer note); both are
  documented.
- **Overlay dismiss races** — the re-entrancy guard is the sharp edge; test fast toggles.
- **Out of scope (explicit):** no libghostty cursor shader; no motion on non-movement
  state (beyond the requested halo + button/chip tints).
