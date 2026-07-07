# Epic 3 — Drawers + lazygit float + zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-tab overlay layer — bottom/right drawers (`⌘B`/`⌘|`), a zoom (`⌘F`), and a lazygit float (`⌘G`) — plus a global toggle dock and a global left sidebar (`⌘E`), all behind the `TerminalSurface` seam.

**Architecture:** Introduce a per-tab `TabController` wrapping the existing `PaneCanvasController` (pane tree) plus the per-tab overlay surfaces; refactor `WindowController` to hold `[TabID: TabController]`. Drawers/lazygit are `TerminalSurface`s created via the shared factory, kept alive when hidden, terminated on tab close. The window gains the global sidebar + dock.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit. Chrome target `Sources/ZenTerm` (imports `TerminalKit`/`PaneKit`/`TabKit` + AppKit; never SwiftTerm).

## Global Constraints

- **Seam intact:** `Sources/ZenTerm` imports `TerminalKit`/`PaneKit`/`TabKit` + AppKit only. Never `import SwiftTerm`. Auxiliary surfaces are created with `TerminalSurfaceFactory.make()` and configured via `TerminalSurfaceConfig`.
- **Swift conventions:** PascalCase types; one primary type per file; filename matches the type. No force-unwrap except documented AppKit (`contentView!`). `required init?(coder:)` → `fatalError("init(coder:) is not used")`.
- **No defer markers** (`TODO`/`FIXME`/`HACK`) and no suppressions.
- **Verify before done:** `swift build` clean **and** `swift test` green (currently 45 tests). AppKit behavior with no unit test is verified against each task's manual runbook via `swift run ZenTerm`.
- **Persistent drawer shells:** a drawer's surface is created lazily on first open, its view is hidden (not destroyed) on toggle-off so the shell/process keeps running, and it is terminated only when the tab closes (folded into `TabController.shutdown()`).
- **Static overlay sizes:** bottom drawer height = **240pt**, right drawer width = **360pt** (constants; no drag-resize this epic).
- **cwd inheritance:** new drawer/lazygit surfaces inherit the tab's focused-pane cwd via `PaneCanvasController.focusedCWD` (live, `proc_pidinfo`-based from Epic 2).
- **Login-shell for aux terminals:** drawer surfaces launch the default shell (login shell, same as panes — pass `command: nil`). lazygit launches via a login shell so Homebrew's `lazygit` is on PATH (see PR3).
- **Keybinds** (via `KeyInterceptor`, consumed — never forwarded to the PTY): `⌘B` bottom drawer, `⌘|` (`⌘⇧\`) right drawer, `⌘F` zoom, `⌘G` lazygit, `⌘E` sidebar. `⌘\` remains vertical-split. All are `⌘`-bare except `⌘|` which is `⌘⇧\`.
- **Iris accent:** `NSColor(srgbRed: 0xc4/255, green: 0xa7/255, blue: 0xe7/255, alpha: 1)` — the shared accent for active dock buttons, zoom indicator, drawer focus.

---

## PR 1 — `TabController` refactor + bottom & right drawers

### Task 1: `TabController` wrapper + `WindowController` refactor (behavior-preserving)

Pure refactor: introduce `TabController` wrapping `PaneCanvasController`, and make `WindowController` hold `[TabID: TabController]`. No drawers yet. The app must behave **identically** afterward (tabs, splits, nav, close cascade, titles, copy/paste, multi-window all unchanged).

**Files:**
- Create: `Sources/ZenTerm/TabController.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`

**Interfaces:**
- Produces `final class TabController: NSObject`:
  - `init(initialCWD: URL?)`
  - `var view: NSView { get }` — the per-tab container (hosts the pane canvas; drawers added later)
  - `func start()`
  - `func split(_ axis: SplitAxis)` / `func navigate(_ direction: Direction)` / `@discardableResult func closeFocused() -> Bool` / `func focusActivePane()`
  - `var title: String` / `var focusedCWD: URL?`
  - `var onTitleChanged: (() -> Void)?` / `var onLastPaneClosed: (() -> Void)?`
  - `func shutdown()`
  - `@objc func copyFromSurface(_ sender: Any?)` / `@objc func pasteToSurface(_ sender: Any?)`
- Consumes: `PaneCanvasController` (Epic 1/2), `SplitAxis`/`Direction` (PaneKit/ZenTerm).

- [ ] **Step 1: Create `TabController` forwarding to a `PaneCanvasController`**

Create `Sources/ZenTerm/TabController.swift`:

```swift
import AppKit
import PaneKit

/// One tab: owns the pane tree (`PaneCanvasController`) and — added in later tasks —
/// the per-tab overlay surfaces (drawers, lazygit) and zoom. `view` is the tab's
/// container that `WindowController` mounts; the pane canvas fills it, with drawers
/// docked to its edges in later tasks.
final class TabController: NSObject {
    let view = NSView()
    private let paneCanvas: PaneCanvasController

    var onTitleChanged: (() -> Void)? {
        get { paneCanvas.onTitleChanged }
        set { paneCanvas.onTitleChanged = newValue }
    }
    var onLastPaneClosed: (() -> Void)? {
        get { paneCanvas.onLastPaneClosed }
        set { paneCanvas.onLastPaneClosed = newValue }
    }

    var title: String { paneCanvas.title }
    var focusedCWD: URL? { paneCanvas.focusedCWD }

    init(initialCWD: URL?) {
        paneCanvas = PaneCanvasController(initialCWD: initialCWD)
        super.init()
        let canvas = paneCanvas.canvasView
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func start() { paneCanvas.start() }
    func split(_ axis: SplitAxis) { paneCanvas.split(axis) }
    func navigate(_ direction: Direction) { paneCanvas.navigate(direction) }
    @discardableResult func closeFocused() -> Bool { paneCanvas.closeFocused() }
    func focusActivePane() { paneCanvas.focusActivePane() }
    func shutdown() { paneCanvas.shutdown() }

    @objc func copyFromSurface(_ sender: Any?) { paneCanvas.copyFromSurface(sender) }
    @objc func pasteToSurface(_ sender: Any?) { paneCanvas.pasteToSurface(sender) }
}
```

> `Direction` is the type `PaneCanvasController.navigate(_:)` already takes (defined in ZenTerm/PaneKit for spatial nav). Use the exact same type; do not redefine it.

- [ ] **Step 2: Refactor `WindowController` to hold `TabController`s**

In `Sources/ZenTerm/WindowController.swift`, replace every `PaneCanvasController` with `TabController` and every `.canvasView` with `.view`. Concretely:
- `private var controllers: [TabID: PaneCanvasController]` → `[TabID: TabController]`.
- `private var activeController: PaneCanvasController?` → `TabController?` (body unchanged).
- `makeController(initialCWD:) -> PaneCanvasController` → `-> TabController` returning `TabController(initialCWD:)`.
- In `mountActive()`, `c.canvasView` → `c.view` (both constraint block and the `mountedCanvas === c.canvasView` check → `c.view`).
- In `closeTab()`, `controller?.canvasView` → `controller?.view`.
- Everything else (`start()`, `split`, `navigate`, `closeFocused`, `focusActivePane`, `title`, `focusedCWD`, `onTitleChanged`, `onLastPaneClosed`, `shutdown`, `copyFromSurface`, `pasteToSurface`) is already exposed by `TabController` with identical signatures — no call-site changes beyond the type name.

- [ ] **Step 3: Build and run the manual runbook**

Run: `swift build` (expected clean), `swift test` (expected 45/45), then `swift run ZenTerm`.

Manual runbook — everything must behave **exactly** as before this task:
1. App opens with one tab; prompt in the focused pane.
2. `⌘\` / `⌘-` split; `⌘h/j/k/l` navigate; halo follows focus.
3. `⌘t` new tab, `⌘1/2` switch, background shells stay alive.
4. `⌘w` cascade (pane → tab → window); `⌘n` new window; close a 2nd window via red button (no crash).
5. Tab titles show cwd basename; `⌘C`/`⌘V` copy/paste.

- [ ] **Step 4: Commit**

```bash
git add Sources/ZenTerm/TabController.swift Sources/ZenTerm/WindowController.swift
git commit -m "refactor(chrome): introduce per-tab TabController wrapping PaneCanvasController"
```

### Task 2: Drawer surface + `DrawerView` + bottom drawer (`⌘B`)

Add the per-tab drawer machinery to `TabController` and wire the bottom drawer with `⌘B`.

**Files:**
- Create: `Sources/ZenTerm/DrawerView.swift`
- Modify: `Sources/ZenTerm/TabController.swift`
- Modify: `Sources/ZenTerm/KeyInterceptor.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`

**Interfaces:**
- Produces:
  - `DrawerView` — `init(edge: DrawerEdge, content: NSView, background: NSColor)`; `enum DrawerEdge { case bottom, right }`.
  - `TabController.toggleBottomDrawer()`; drawers created via `TerminalSurfaceFactory.make()` + `TerminalSurfaceConfig(workingDirectory: focusedCWD, theme: Theme.rosePineMoon)`.
  - `KeyInterceptor.ReservedChord` gains `.toggleBottomDrawer` (`⌘B`).
- Consumes: `TerminalSurface`, `TerminalSurfaceFactory`, `TerminalSurfaceConfig` (TerminalKit); `Theme.rosePineMoon`.

- [ ] **Step 1: Create `DrawerView`**

Create `Sources/ZenTerm/DrawerView.swift`:

```swift
import AppKit

enum DrawerEdge { case bottom, right }

/// A fixed-size container docking one terminal surface at the tab region's bottom or
/// right edge, with a subtle divider line on the inner edge and padding matching the
/// panes. The hosted surface view fills the padded area.
final class DrawerView: NSView {
    static let bottomHeight: CGFloat = 240
    static let rightWidth: CGFloat = 360

    private static let divider = NSColor(white: 1, alpha: 0.08)

    init(edge: DrawerEdge, content: NSView, background: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = background.cgColor

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Self.divider.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let pad: CGFloat = 10
        var cs: [NSLayoutConstraint] = [
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            content.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ]
        switch edge {
        case .bottom:
            cs += [
                heightAnchor.constraint(equalToConstant: Self.bottomHeight),
                line.topAnchor.constraint(equalTo: topAnchor),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ]
        case .right:
            cs += [
                widthAnchor.constraint(equalToConstant: Self.rightWidth),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.topAnchor.constraint(equalTo: topAnchor),
                line.bottomAnchor.constraint(equalTo: bottomAnchor),
                line.widthAnchor.constraint(equalToConstant: 1),
            ]
        }
        NSLayoutConstraint.activate(cs)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
```

- [ ] **Step 2: Add the bottom-drawer lifecycle to `TabController`**

The `TabController.view` layout must become: the pane canvas fills the region, with the bottom drawer docked below it when open (canvas bottom then pins to the drawer top instead of the view bottom). Rework `TabController` so the pane-canvas bottom constraint is swappable.

In `Sources/ZenTerm/TabController.swift`, replace the fixed canvas constraints with a stored, re-derivable layout, and add the drawer state. Add imports `import TerminalKit`. Add:

```swift
    // Per-tab auxiliary surfaces (created lazily; kept alive when hidden).
    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerView: DrawerView?
    private var isBottomOpen = false

    private let canvas: NSView            // paneCanvas.canvasView, cached
    private var canvasBottom: NSLayoutConstraint!
```

In `init`, cache `canvas = paneCanvas.canvasView` and keep the leading/trailing/top constraints, but store the bottom one so it can be re-pointed:

```swift
        canvas = paneCanvas.canvasView
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        canvasBottom = canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvasBottom,
        ])
```

Add the toggle + lazy creation:

```swift
    /// Toggle the bottom drawer. First open creates a persistent login-shell surface
    /// in the tab's cwd; toggling hidden keeps it running; it dies only in shutdown().
    func toggleBottomDrawer() {
        if isBottomOpen {
            isBottomOpen = false
            bottomDrawerView?.isHidden = true
            canvasBottom.isActive = true
            paneCanvas.focusActivePane()
            return
        }
        isBottomOpen = true
        let drawerView = ensureBottomDrawerView()
        drawerView.isHidden = false
        canvasBottom.isActive = false
        drawerView.topAnchor.constraint(greaterThanOrEqualTo: canvas.bottomAnchor).isActive = false
        // canvas bottom now pins to the drawer top:
        canvas.bottomAnchor.constraint(equalTo: drawerView.topAnchor).isActive = true
        bottomDrawerSurface?.focus()
    }

    private func ensureBottomDrawerView() -> DrawerView {
        if let existing = bottomDrawerView { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.start(TerminalSurfaceConfig(workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        bottomDrawerSurface = surface
        let dv = DrawerView(edge: .bottom, content: surface.view,
                            background: Theme.rosePineMoon.background.nsColor)
        view.addSubview(dv)
        NSLayoutConstraint.activate([
            dv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        bottomDrawerView = dv
        return dv
    }
```

> The implementer must make the canvas-bottom re-pointing clean: keep ONE mutable bottom constraint reference for the canvas and toggle its target between `view.bottomAnchor` (closed) and `bottomDrawerView.topAnchor` (open), rather than accumulating constraints. The snippet above sketches intent — implement it as a single swapped constraint (deactivate the old, activate the new) with no leaked/duplicate constraints. **Requirement:** opening docks the 240pt drawer below the canvas; closing returns the canvas to full height; the surface persists across toggles.

Update `shutdown()` to terminate the drawer:

```swift
    func shutdown() {
        paneCanvas.shutdown()
        bottomDrawerSurface?.terminate()
        bottomDrawerSurface = nil
    }
```

- [ ] **Step 3: Add `.toggleBottomDrawer` (`⌘B`) to `KeyInterceptor`**

In `Sources/ZenTerm/KeyInterceptor.swift`, add `case toggleBottomDrawer` to `ReservedChord`, and in the `switch key` (bare-`⌘` branch) add:

```swift
            case "b": chord = .toggleBottomDrawer
```

- [ ] **Step 4: Route `⌘B` in `WindowController`**

In `WindowController.handle(_:)`, add to the switch:

```swift
        case .toggleBottomDrawer: active?.toggleBottomDrawer()
```

- [ ] **Step 5: Build and run the manual runbook**

Run: `swift build` (clean), `swift test` (45/45), `swift run ZenTerm`.

Runbook:
1. `⌘B` → a 240pt terminal drawer docks at the bottom with its own live shell in the current cwd; the pane canvas shrinks above it.
2. Run `ping localhost` in the drawer, `⌘B` to hide, wait, `⌘B` to show → ping output **accumulated** (shell kept running).
3. `cd ~/Dev` in a pane, then `⌘B` (first open) → drawer starts in `~/Dev` (cwd inheritance).
4. Switch tabs (`⌘t`, `⌘1/2`) → each tab has its own bottom drawer state; a background tab's drawer shell keeps running.
5. Close a tab with an open drawer (`⌘w` to last pane) → drawer shell terminates (no zombie `ping`).

- [ ] **Step 6: Commit**

```bash
git add Sources/ZenTerm/DrawerView.swift Sources/ZenTerm/TabController.swift Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/WindowController.swift
git commit -m "feat(drawers): per-tab bottom drawer (⌘B) with persistent shell"
```

### Task 3: Right drawer (`⌘|`)

Mirror the bottom drawer at the right edge, toggled by `⌘|` (`⌘⇧\`). This requires `KeyInterceptor` to intercept one `⌘⇧` chord.

**Files:**
- Modify: `Sources/ZenTerm/TabController.swift`
- Modify: `Sources/ZenTerm/KeyInterceptor.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`

**Interfaces:**
- Produces: `TabController.toggleRightDrawer()`; `KeyInterceptor.ReservedChord.toggleRightDrawer` (`⌘⇧\`).

- [ ] **Step 1: Add the right-drawer lifecycle to `TabController`**

Add, mirroring the bottom drawer but on the trailing edge (fixed width 360pt) and re-pointing the canvas **trailing** constraint. Store `canvasTrailing: NSLayoutConstraint!` (like `canvasBottom`), initialized in `init` to `canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor)`. Add:

```swift
    private var rightDrawerSurface: TerminalSurface?
    private var rightDrawerView: DrawerView?
    private var isRightOpen = false

    func toggleRightDrawer() {
        if isRightOpen {
            isRightOpen = false
            rightDrawerView?.isHidden = true
            canvasTrailing.isActive = true       // canvas trailing back to view edge
            paneCanvas.focusActivePane()
            return
        }
        isRightOpen = true
        let dv = ensureRightDrawerView()
        dv.isHidden = false
        canvasTrailing.isActive = false
        canvas.trailingAnchor.constraint(equalTo: dv.leadingAnchor).isActive = true
        rightDrawerSurface?.focus()
    }

    private func ensureRightDrawerView() -> DrawerView {
        if let existing = rightDrawerView { return existing }
        let surface = TerminalSurfaceFactory.make()
        surface.start(TerminalSurfaceConfig(workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        rightDrawerSurface = surface
        let dv = DrawerView(edge: .right, content: surface.view,
                            background: Theme.rosePineMoon.background.nsColor)
        view.addSubview(dv)
        NSLayoutConstraint.activate([
            dv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dv.topAnchor.constraint(equalTo: view.topAnchor),
            dv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rightDrawerView = dv
        return dv
    }
```

> Same clean-constraint requirement as Task 2: keep a single swappable `canvasTrailing` reference. Note the right drawer spans the **full tab height** (top→bottom of `view`), independent of whether the bottom drawer is open (matches the prototype's full-height right drawer). If both are open, the right drawer overlaps the bottom drawer's column on the right; acceptable for this pass (fixed sizes) — the implementer should pin the right drawer to `view` top/bottom so it's full height, and the bottom drawer to `view` leading/trailing so it spans full width under the canvas. The canvas occupies the remaining top-left rectangle.

Extend `shutdown()` to also terminate the right drawer:

```swift
        rightDrawerSurface?.terminate()
        rightDrawerSurface = nil
```

- [ ] **Step 2: Add `.toggleRightDrawer` (`⌘⇧\`) to `KeyInterceptor`**

`KeyInterceptor` currently only intercepts bare-`⌘` (`flags == .command`). Add a narrow allowance for `⌘⇧\`. In `start()`'s handler, after computing `flags`, replace the single bare-`⌘` guard with handling for both the bare-`⌘` set and this one `⌘⇧` chord:

```swift
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()

            // The one reserved ⌘⇧ chord: ⌘⇧\ ( "⌘|" ) → right drawer. With shift held,
            // charactersIgnoringModifiers is "|"; also accept "\\" defensively.
            if flags == [.command, .shift], key == "|" || key == "\\" {
                self.onReservedChord?(.toggleRightDrawer)
                return nil
            }

            guard flags == .command else { return event }   // all other reserved chords are bare-⌘
```

Add `case toggleRightDrawer` to `ReservedChord`. Leave the bare-`⌘` `switch key` block unchanged.

- [ ] **Step 3: Route `⌘|` in `WindowController`**

In `WindowController.handle(_:)`, add:

```swift
        case .toggleRightDrawer: active?.toggleRightDrawer()
```

- [ ] **Step 4: Build and run the manual runbook**

Run: `swift build` (clean), `swift test` (45/45), `swift run ZenTerm`.

Runbook:
1. `⌘|` (Shift+⌘+`\`) → a 360pt full-height terminal drawer docks at the right with a live shell; canvas shrinks to its left.
2. Persistence + cwd inheritance + per-tab + terminate-on-tab-close: same checks as the bottom drawer.
3. Open both `⌘B` and `⌘|` → bottom spans the width below the canvas, right spans full height; both host live shells; `⌘\`/`⌘-`/`⌘h j k l` still operate on the pane canvas.
4. Confirm `⌘\` (vertical split) still works and is distinct from `⌘|` (right drawer).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/TabController.swift Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/WindowController.swift
git commit -m "feat(drawers): per-tab right drawer (⌘|) with persistent shell"
```

---

## PR 2 — Zoom (`⌘F`)

Ship PR1 first (merge). Branch PR2 from the ticket's Linear `gitBranchName`.

### Task 4: Pane single-leaf zoom in `PaneCanvasController`

Let `PaneCanvasController` render a single leaf full-canvas (surface retained), plus a zoom indicator on the zoomed pane.

**Files:**
- Modify: `Sources/ZenTerm/PaneCanvasController.swift`
- Modify: `Sources/ZenTerm/PaneHostView.swift`

**Interfaces:**
- Produces: `PaneCanvasController.zoomFocusedLeaf()` / `unzoom()` / `var isZoomed: Bool`; `PaneHostView.isZoomed` (shows an iris corner badge).

- [ ] **Step 1: Add a zoom indicator to `PaneHostView`**

In `Sources/ZenTerm/PaneHostView.swift`, add an `isZoomed` flag that shows a small iris corner badge (a rounded pill with a ⤢ glyph, top-right, inside the pane padding). Add:

```swift
    var isZoomed: Bool = false { didSet { zoomBadge.isHidden = !isZoomed } }

    private lazy var zoomBadge: NSView = {
        let badge = NSTextField(labelWithString: "⤢")
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        badge.textColor = Self.iris
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        badge.layer?.cornerRadius = 5
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 18),
        ])
        return badge
    }()
```

> `Self.iris` and `pane` already exist in `PaneHostView` (Epic 1). Reference `zoomBadge` in `init`'s tail (e.g. `_ = zoomBadge`) so the lazy view is created, or build it eagerly — the requirement is the badge exists and toggles with `isZoomed`.

- [ ] **Step 2: Add zoom state + single-leaf render to `PaneCanvasController`**

In `Sources/ZenTerm/PaneCanvasController.swift`, add `private var zoomedLeaf: PaneID?` and `var isZoomed: Bool { zoomedLeaf != nil }`. In `rebuildViews()`, when `zoomedLeaf` is set and still present in the tree, render just that leaf's host filling the canvas (skip the `SplitContainerView`):

```swift
    private func rebuildViews() {
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        hostByLeaf.removeAll(keepingCapacity: true)

        let rootView: NSView
        if let zoomed = zoomedLeaf, tree.leafIDs.contains(zoomed) {
            rootView = hostView(for: zoomed)
        } else {
            rootView = SplitContainerView(node: tree.root, leafView: { [weak self] id in
                self?.hostView(for: id) ?? NSView()
            })
        }
        canvasView.addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor, constant: 12),
            rootView.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor, constant: -12),
            rootView.topAnchor.constraint(equalTo: canvasView.topAnchor, constant: 36),
            rootView.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: -12),
        ])
        updateHalo()
    }
```

> Preserve the exact inset constants (12 / 12 / 36 / 12) already in `rebuildViews()` — copy them verbatim from the current file; do not change padding. `hostView(for:)` and `updateHalo()` are unchanged. `SplitContainerView` sets its own `translatesAutoresizingMaskIntoConstraints=false`; a lone `PaneHostView` from `hostView(for:)` also does (Epic 1). Ensure the zoomed host has `translatesAutoresizingMaskIntoConstraints=false` before adding constraints.

Add the toggle methods + mark the zoomed host:

```swift
    /// Zoom the focused leaf to fill the canvas; re-render. No-op if already zoomed.
    func zoomFocusedLeaf() {
        guard zoomedLeaf == nil else { return }
        zoomedLeaf = tree.focusedLeaf
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
    }

    /// Restore the split layout.
    func unzoom() {
        guard zoomedLeaf != nil else { return }
        zoomedLeaf = nil
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
    }
```

In `updateHalo()`, also set the zoom badge on the host:

```swift
    private func updateHalo() {
        for (id, host) in hostByLeaf {
            host.isFocused = (id == tree.focusedLeaf)
            host.isZoomed = (id == zoomedLeaf)
        }
    }
```

> `reconcileAndRender()` diffs surfaces then calls `rebuildViews()`; zooming/unzooming does NOT change `tree.leafIDs`, so no surface is created/terminated — the shell is retained. Confirm `zoomedLeaf` is cleared if its leaf is closed while zoomed: in `closeFocused()` and the delegate exit path, add `if zoomedLeaf != nil, !tree.leafIDs.contains(zoomedLeaf!) { zoomedLeaf = nil }` before `reconcileAndRender()`. Implement this guard so closing the zoomed pane cleanly returns to the split view.

- [ ] **Step 3: Build + unit sanity**

Run: `swift build` (clean), `swift test` (45/45 — no new unit test; pane zoom is AppKit-verified in Task 5's runbook once `⌘F` is wired).

- [ ] **Step 4: Commit**

```bash
git add Sources/ZenTerm/PaneCanvasController.swift Sources/ZenTerm/PaneHostView.swift
git commit -m "feat(zoom): PaneCanvasController single-leaf zoom + pane zoom badge"
```

### Task 5: `TabController` zoom orchestration + `⌘F` wiring

`TabController` decides whether the focused surface is a pane or a drawer and zooms accordingly, hiding siblings; `⌘F` toggles.

**Files:**
- Modify: `Sources/ZenTerm/TabController.swift`
- Modify: `Sources/ZenTerm/DrawerView.swift`
- Modify: `Sources/ZenTerm/KeyInterceptor.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`

**Interfaces:**
- Produces: `TabController.toggleZoom()`; `KeyInterceptor.ReservedChord.toggleZoom` (`⌘F`); focus-kind tracking so `toggleZoom` targets the focused surface.

- [ ] **Step 1: Track the focused surface kind in `TabController`**

`TabController` needs to know whether focus is in a pane or a drawer to choose the zoom target. Track a `focusedKind` updated when a drawer gains focus (drawers focus on toggle-open and on click) and reset to `.pane` when a pane is focused. Add:

```swift
    private enum FocusKind { case pane, bottomDrawer, rightDrawer }
    private var focusedKind: FocusKind = .pane
```

Set `focusedKind = .bottomDrawer` in `toggleBottomDrawer`'s open branch (after `bottomDrawerSurface?.focus()`), `.rightDrawer` in `toggleRightDrawer`'s open branch, and `.pane` whenever the pane canvas regains focus. To catch pane clicks, set `paneCanvas.onTitleChanged`… no — instead expose a focus hook: in `PaneCanvasController.focus(_:)` there is already an `onTitleChanged` fire; add a dedicated `var onFocusChanged: (() -> Void)?` fired in `focus(_:)`, and in `TabController` set `paneCanvas.onFocusChanged = { [weak self] in self?.focusedKind = .pane }`.

> Add `var onFocusChanged: (() -> Void)?` to `PaneCanvasController` and fire it inside `focus(_:)` (right after `onTitleChanged?()`). Also add drawer click-focus: `DrawerView` gains an `onFocusRequest: (() -> Void)?` invoked from `mouseDown`, and `TabController` sets it to update `focusedKind` + focus that drawer's surface. Implement both so clicking a pane or a drawer updates `focusedKind`.

- [ ] **Step 2: Add `onFocusRequest` to `DrawerView`**

In `DrawerView`, add `var onFocusRequest: (() -> Void)?` and:

```swift
    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }
```

- [ ] **Step 3: Add zoom orchestration to `TabController`**

```swift
    private var isZoomed = false

    /// Zoom the focused surface (pane or drawer) to fill the tab; hide siblings.
    /// Ignored while the lazygit float is open (added in PR3 via `isLazygitOpen`).
    func toggleZoom() {
        if isZoomed { exitZoom(); return }
        switch focusedKind {
        case .pane:
            paneCanvas.zoomFocusedLeaf()
            bottomDrawerView?.isHidden = true
            rightDrawerView?.isHidden = true
        case .bottomDrawer:
            guard let dv = bottomDrawerView, isBottomOpen else { return }
            zoomDrawer(dv)
        case .rightDrawer:
            guard let dv = rightDrawerView, isRightOpen else { return }
            zoomDrawer(dv)
        }
        isZoomed = true
    }

    private func exitZoom() {
        isZoomed = false
        paneCanvas.unzoom()
        restoreDrawerLayout()   // re-show whichever drawers were open, per isBottomOpen/isRightOpen
    }
```

> The implementer designs `zoomDrawer(_:)` and `restoreDrawerLayout()`: zooming a drawer pins that `DrawerView` to fill the whole `view` (leading/trailing/top/bottom to `view`, overriding its docked constraints) and hides the canvas + the other drawer; `restoreDrawerLayout()` returns the `DrawerView` to its docked size and un-hides the canvas and any open drawers. Use a saved set of "zoom constraints" activated/deactivated as a group so restore is exact. **Requirement:** `⌘F` on a focused pane shows only that pane full-tab with the badge; `⌘F` on a focused drawer shows only that drawer full-tab; `⌘F` again (or Escape, wired in PR3) restores the exact prior layout including open drawers.

Add the Escape path now as a public method so PR3's float and this share it: `func exitZoomIfNeeded() -> Bool { if isZoomed { exitZoom(); return true }; return false }`.

- [ ] **Step 4: Add `.toggleZoom` (`⌘F`) to `KeyInterceptor` + route**

In `KeyInterceptor`, add `case toggleZoom` and `case "f": chord = .toggleZoom` in the bare-`⌘` switch. In `WindowController.handle(_:)` add `case .toggleZoom: active?.toggleZoom()`.

- [ ] **Step 5: Build and run the manual runbook**

Run: `swift build` (clean), `swift test` (45/45), `swift run ZenTerm`.

Runbook:
1. Split into 2+ panes; focus one; `⌘F` → that pane fills the tab with an iris ⤢ badge; `⌘F` → back to the split, same focus.
2. `⌘B` open the bottom drawer, click it, `⌘F` → the drawer fills the tab; `⌘F` → back to canvas + drawer docked as before.
3. Zoom a pane while a drawer is open → drawer hidden during zoom, reappears on unzoom.
4. Close the zoomed pane (`⌘w`) → cleanly returns to the split (no blank canvas).

- [ ] **Step 6: Commit**

```bash
git add Sources/ZenTerm/TabController.swift Sources/ZenTerm/DrawerView.swift Sources/ZenTerm/PaneCanvasController.swift Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/WindowController.swift
git commit -m "feat(zoom): ⌘F zooms focused pane or drawer to fill the tab"
```

---

## PR 3 — lazygit float (`⌘G`)

Ship PR2 first (merge). Branch PR3 from the ticket's Linear `gitBranchName`.

### Task 6: `LazygitOverlay` + per-tab float

**Files:**
- Create: `Sources/ZenTerm/LazygitOverlay.swift`
- Modify: `Sources/ZenTerm/TabController.swift`
- Modify: `Sources/ZenTerm/KeyInterceptor.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`

**Interfaces:**
- Produces: `LazygitOverlay` (centered float + dimmed backdrop hosting a surface view); `TabController.toggleLazygit()` + `var isLazygitOpen: Bool`; `KeyInterceptor.ReservedChord.toggleLazygit` (`⌘G`) + `.dismissOverlay` (Escape).

- [ ] **Step 1: Create `LazygitOverlay`**

Create `Sources/ZenTerm/LazygitOverlay.swift`: a full-`view` overlay with a dimmed backdrop (`NSColor(white:0, alpha:0.55)`) and a centered rounded card (`min(920, 90%)` × `min(600, 80%)`) hosting `content`. Clicking the backdrop invokes `onDismiss`; the card swallows clicks.

```swift
import AppKit

/// A centered floating card over the tab, dimmed backdrop behind it, hosting the
/// lazygit surface. Backdrop click calls onDismiss; the card itself does not.
final class LazygitOverlay: NSView {
    private let onDismiss: () -> Void

    init(content: NSView, background: NSColor, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        let w = card.widthAnchor.constraint(equalToConstant: 920)
        w.priority = .defaultHigh
        let h = card.heightAnchor.constraint(equalToConstant: 600)
        h.priority = .defaultHigh
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            w, h,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.8),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private final class BackdropView: NSView {
        private let onClick: () -> Void
        init(onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
```

- [ ] **Step 2: Add the lazygit lifecycle to `TabController`**

Add per-tab lazygit state. The surface runs `lazygit` via a login shell so PATH resolves (Epic 0 login-shell rationale): pass `command` = the user's shell, `args` = `["-l", "-c", "lazygit"]`. On the surface's exit, auto-close.

```swift
    private var lazygitSurface: TerminalSurface?
    private var lazygitOverlay: LazygitOverlay?
    var isLazygitOpen: Bool { lazygitOverlay != nil }

    func toggleLazygit() {
        if isLazygitOpen { closeLazygit(); return }
        if isZoomed { exitZoom() }   // mutually exclusive with zoom
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let surface = TerminalSurfaceFactory.make()
        surface.delegate = self
        surface.start(TerminalSurfaceConfig(command: shell, args: ["-l", "-c", "lazygit"],
                                            workingDirectory: focusedCWD, theme: Theme.rosePineMoon))
        lazygitSurface = surface
        let overlay = LazygitOverlay(content: surface.view,
                                     background: Theme.rosePineMoon.background.nsColor,
                                     onDismiss: { [weak self] in self?.closeLazygit() })
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)   // topmost — above canvas/drawers
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        lazygitOverlay = overlay
        surface.focus()
    }

    private func closeLazygit() {
        lazygitOverlay?.removeFromSuperview()
        lazygitOverlay = nil
        lazygitSurface?.terminate()
        lazygitSurface = nil
        paneCanvas.focusActivePane()
    }
```

`TabController` must adopt `TerminalSurfaceDelegate` to catch lazygit exit → auto-close. Add:

```swift
extension TabController: TerminalSurfaceDelegate {
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        if s === lazygitSurface { closeLazygit() }
    }
}
```

> `TerminalSurfaceDelegate` has default no-op methods (Epic 0), so only `surfaceDidExit` is needed. Import `TerminalKit`. Extend `shutdown()` to terminate `lazygitSurface` too. Make `toggleZoom()` early-return when `isLazygitOpen` (mutual exclusion): add `guard !isLazygitOpen else { return }` at its top.

- [ ] **Step 3: Add `⌘G` + Escape to `KeyInterceptor` + route**

Add `case toggleLazygit` and `case dismissOverlay` to `ReservedChord`. Add `case "g": chord = .toggleLazygit` in the bare-`⌘` switch. Escape has no `⌘`: add a separate branch **before** the `flags == .command` guard:

```swift
            if flags.isEmpty, event.keyCode == 53 {   // 53 = Escape
                self.onReservedChord?(.dismissOverlay)
                return event   // let Escape ALSO reach the PTY unless an overlay consumed it
            }
```

> Escape must still reach the terminal normally (vim, etc.). So `dismissOverlay` returns `event` (not nil) — the chrome closes an overlay if one is open, but Escape is never swallowed from the PTY. `WindowController` routes `.dismissOverlay` to the active tab, which closes the float or unzoom only if one is active. Wire routing: `case .toggleLazygit: active?.toggleLazygit()` and `case .dismissOverlay: active?.dismissTopOverlay()`. Add `func dismissTopOverlay() { if isLazygitOpen { closeLazygit() } else { _ = exitZoomIfNeeded() } }` to `TabController`.

- [ ] **Step 4: Build and run the manual runbook**

Run: `swift build` (clean), `swift test` (45/45), `swift run ZenTerm`. (Requires `lazygit` installed: `brew install lazygit`.)

Runbook:
1. In a git repo pane, `⌘G` → a centered lazygit float opens over the tab, dimmed backdrop, running lazygit in that repo's cwd.
2. `q` inside lazygit (process exits) → float auto-closes.
3. `⌘G` open, then Escape / backdrop click → float closes; Escape still works inside vim in a pane afterward.
4. `⌘F` while the float is open → ignored (no zoom under float).
5. Float is per-tab: open on tab 1, switch to tab 2 → tab 2 has no float; back to tab 1 → float still there.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/LazygitOverlay.swift Sources/ZenTerm/TabController.swift Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/WindowController.swift
git commit -m "feat(lazygit): per-tab ⌘G lazygit float, login-shell launch, auto-close on exit"
```

---

## PR 4 — Toggle dock

Ship PR3 first (merge). Branch from the ticket's `gitBranchName`.

### Task 7: `ToggleDock` global widget

**Files:**
- Create: `Sources/ZenTerm/ToggleDock.swift`
- Modify: `Sources/ZenTerm/TabController.swift` (expose overlay-state snapshot + `onOverlayStateChanged`)
- Modify: `Sources/ZenTerm/WindowController.swift` (host the dock in the tab-bar row, refresh on toggle + tab switch)

**Interfaces:**
- Produces: `ToggleDock` (button row: split-v, split-h | bottom, right, lazygit); `struct OverlayState { var isBottomOpen, isRightOpen, isLazygitOpen: Bool }`; `TabController.overlayState: OverlayState` + `var onOverlayStateChanged: (() -> Void)?` fired on any toggle.
- Consumes: the same actions `WindowController.handle` already invokes.

- [ ] **Step 1: Expose overlay state from `TabController`**

Add `struct OverlayState { var isBottomOpen: Bool; var isRightOpen: Bool; var isLazygitOpen: Bool }`, a computed `var overlayState: OverlayState { .init(isBottomOpen: isBottomOpen, isRightOpen: isRightOpen, isLazygitOpen: isLazygitOpen) }`, and `var onOverlayStateChanged: (() -> Void)?`. Fire it at the end of `toggleBottomDrawer`, `toggleRightDrawer`, `toggleLazygit`, and `closeLazygit`.

- [ ] **Step 2: Create `ToggleDock`**

Create `Sources/ZenTerm/ToggleDock.swift`: a horizontal `NSStackView` of icon buttons using SF Symbols (`rectangle.split.2x1` split-v, `rectangle.split.1x2` split-h, `rectangle.bottomthird.inset.filled` bottom, `rectangle.trailingthird.inset.filled` right, `arrow.triangle.branch` lazygit). Active buttons tint iris. Buttons call injected closures. Provide `func render(_ state: OverlayState)` to update active tints.

```swift
import AppKit

final class ToggleDock: NSView {
    static let iris = NSColor(srgbRed: 0xc4/255.0, green: 0xa7/255.0, blue: 0xe7/255.0, alpha: 1)
    private let idle = NSColor(white: 0.92, alpha: 0.5)

    private let bottomBtn: NSButton
    private let rightBtn: NSButton
    private let lazygitBtn: NSButton

    init(onSplitV: @escaping () -> Void, onSplitH: @escaping () -> Void,
         onBottom: @escaping () -> Void, onRight: @escaping () -> Void, onLazygit: @escaping () -> Void) {
        func btn(_ symbol: String, _ action: @escaping () -> Void) -> NSButton {
            let b = NSButton(); b.isBordered = false; b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.contentTintColor = NSColor(white: 0.92, alpha: 0.5)
            b.target = ActionProxy(action); b.action = #selector(ActionProxy.fire)
            objc_setAssociatedObject(b, Unmanaged.passUnretained(b).toOpaque(), b.target, .OBJC_ASSOCIATION_RETAIN)
            return b
        }
        bottomBtn = btn("rectangle.bottomthird.inset.filled", onBottom)
        rightBtn = btn("rectangle.trailingthird.inset.filled", onRight)
        lazygitBtn = btn("arrow.triangle.branch", onLazygit)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let splitV = btn("rectangle.split.2x1", onSplitV)
        let splitH = btn("rectangle.split.1x2", onSplitH)
        let sep = NSBox(); sep.boxType = .separator
        let stack = NSStackView(views: [splitV, splitH, sep, bottomBtn, rightBtn, lazygitBtn])
        stack.orientation = .horizontal; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ state: OverlayState) {
        bottomBtn.contentTintColor = state.isBottomOpen ? Self.iris : idle
        rightBtn.contentTintColor = state.isRightOpen ? Self.iris : idle
        lazygitBtn.contentTintColor = state.isLazygitOpen ? Self.iris : idle
    }

    private final class ActionProxy: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
```

> The `ActionProxy` retention via `objc_setAssociatedObject` keeps each button's target alive (NSButton.target is weak). The implementer may instead store the proxies in an array property on `ToggleDock` — cleaner. **Requirement:** buttons fire their closures and don't dangle; active overlays tint iris.

- [ ] **Step 3: Host the dock in `WindowController`, refresh on toggle + tab switch**

In `WindowController.layoutContainer()`, add a `ToggleDock` pinned to the tab-bar row's trailing edge (same vertical center as the tab bar). Its closures call `activeController?.split(.vertical)` / `.split(.horizontal)` / `.toggleBottomDrawer()` / `.toggleRightDrawer()` / `.toggleLazygit()`, then refresh. Wire `activeController?.onOverlayStateChanged` (in `wire(_:id:)`) and call `dock.render(active.overlayState)` from `mountActive()`/`select()` so it mirrors the active tab. Add a `renderDock()` helper and call it after toggles + on tab switch.

> `wire(_:id:)` in `WindowController` currently binds `onTitleChanged`/`onLastPaneClosed` on the tab's controller. Extend it to also set `onOverlayStateChanged = { [weak self] in self?.renderDock() }`. `renderDock()` reads `activeController?.overlayState` (nil → all-false) and calls `dock.render`. Keep the tab bar left-aligned and the dock right-aligned in the same bottom row (tab bar `trailing ≤ dock.leading`).

- [ ] **Step 4: Build and run the manual runbook**

Runbook:
1. Dock shows bottom/right/lazygit buttons bottom-right; clicking each toggles the matching overlay; active ones tint iris.
2. Split buttons split the active pane.
3. Open the bottom drawer on tab 1, switch to tab 2 → dock's bottom button goes inactive (tab 2 has no drawer); back to tab 1 → active again.
4. Keybinds and dock stay in sync (toggle via `⌘B`, dock updates).

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/ToggleDock.swift Sources/ZenTerm/TabController.swift Sources/ZenTerm/WindowController.swift
git commit -m "feat(dock): global toggle dock mirroring the active tab's overlays"
```

---

## PR 5 — Global left sidebar (`⌘E`)

Ship PR4 first (merge). Branch from the ticket's `gitBranchName`.

### Task 8: `SidebarView` + `⌘E` toggle

**Files:**
- Create: `Sources/ZenTerm/SidebarView.swift`
- Modify: `Sources/ZenTerm/WindowController.swift`
- Modify: `Sources/ZenTerm/KeyInterceptor.swift`

**Interfaces:**
- Produces: `SidebarView` (a fixed-width styled panel, minimal placeholder content); `WindowController` global sidebar toggle; `KeyInterceptor.ReservedChord.toggleSidebar` (`⌘E`).

- [ ] **Step 1: Create `SidebarView`**

Create `Sources/ZenTerm/SidebarView.swift`: a 220pt-wide panel (rounded, `Theme` panel bg, subtle border) with a "workspace" heading and a couple of placeholder section labels (Sessions / SSH / Snippets) styled like the prototype — static, no behavior. Content is intentionally minimal (Epic 4 populates it).

```swift
import AppKit

/// The global left sidebar (per-window). A minimal styled panel shell; its real
/// content (sessions/SSH/snippets) arrives with the Epic 4 workspace model.
final class SidebarView: NSView {
    static let width: CGFloat = 220

    init(background: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor

        let heading = NSTextField(labelWithString: "WORKSPACE")
        heading.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        heading.textColor = NSColor(white: 0.92, alpha: 0.45)
        let sections = ["Sessions", "SSH", "Snippets"].map { title -> NSTextField in
            let l = NSTextField(labelWithString: title)
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = NSColor(white: 0.92, alpha: 0.7)
            return l
        }
        let stack = NSStackView(views: [heading] + sections)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
```

- [ ] **Step 2: Add the global sidebar to `WindowController`**

The sidebar docks at the container's leading edge, full height above the tab-bar row, when open; the tab region (mounted tab `view`) then pins its leading to the sidebar's trailing instead of the container leading. Store `isSidebarOpen` + a swappable leading constraint for the mounted region (mirror the `mountActive` leading pin). Add `toggleSidebar()`:

```swift
    private var sidebar: SidebarView?
    private var isSidebarOpen = false

    func toggleSidebar() {
        if isSidebarOpen {
            isSidebarOpen = false
            sidebar?.isHidden = true
            // mounted region leading back to container leading
            relayoutMountedLeading(toSidebar: false)
            return
        }
        isSidebarOpen = true
        let sb = ensureSidebar()
        sb.isHidden = false
        relayoutMountedLeading(toSidebar: true)
    }
```

> The implementer integrates this with the existing `mountActive()` constraints: today the mounted tab `view` pins leading/trailing/top to the container and bottom to the tab bar. Add a stored `mountedLeading` constraint that points to either `container.leadingAnchor` (sidebar closed) or `sidebar.trailingAnchor + gap` (open), re-pointed by `relayoutMountedLeading`. `ensureSidebar()` creates the `SidebarView` once, pins it leading/top to container with an 8pt inset and bottom to the tab bar top. **Requirement:** `⌘E` slides a 220pt panel in at the left, shifting the tab region right; toggling hides it and the tab region reclaims the width. Global (shared across tabs).

- [ ] **Step 3: Add `⌘E` + route**

In `KeyInterceptor`, add `case toggleSidebar` and `case "e": chord = .toggleSidebar` (bare-`⌘`). In `WindowController.handle(_:)`, add `case .toggleSidebar: toggleSidebar()` (note: on `self`, the window — NOT the active tab). Also add a dock button for the sidebar if desired (optional; the dock's sidebar button can call `toggleSidebar` and reflect `isSidebarOpen`).

> Since the sidebar is per-window global state (not per-tab), the dock's sidebar indicator reflects `isSidebarOpen` directly, unlike the drawer buttons. Wiring the sidebar into the dock is optional polish — the requirement is `⌘E` toggles the global sidebar. If added to the dock, refresh it in `renderDock()`.

- [ ] **Step 4: Build and run the manual runbook**

Runbook:
1. `⌘E` → a 220pt sidebar panel appears at the left; the tab region (with its tabs/panes/drawers) shifts right. `⌘E` again → hides, region reclaims width.
2. The sidebar is global: it stays put as you switch tabs (`⌘1/2`) and shows for all tabs in the window.
3. A second window (`⌘n`) has its own independent sidebar state.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZenTerm/SidebarView.swift Sources/ZenTerm/WindowController.swift Sources/ZenTerm/KeyInterceptor.swift
git commit -m "feat(sidebar): global left sidebar (⌘E), minimal panel shell"
```

---

## Self-review

- **Spec coverage:** bottom drawer (Task 2), right drawer (Task 3), zoom pane+drawer (Tasks 4–5), lazygit float (Task 6), toggle dock mirroring active tab (Task 7), global sidebar (Task 8), per-tab persistent shells (Task 2/3 lifecycle + `shutdown`), cwd inheritance (drawer/lazygit `focusedCWD`), lazygit auto-close (Task 6 delegate), zoom↔float mutual exclusion (Task 6 `toggleZoom` guard + `toggleLazygit` exitZoom), Escape topmost-first (Task 6 `dismissTopOverlay`), static sizes (constants), keybinds incl. `⌘|` `⌘⇧\` handling (Task 3), `⌘F`/`⌘G`/`⌘E`. All map to tasks.
- **Refactor isolation:** Task 1 is a pure behavior-preserving refactor with its own runbook — the riskiest change (WindowController holding TabController) is gated before any drawer work.
- **Type consistency:** `TabController` methods (`toggleBottomDrawer`/`toggleRightDrawer`/`toggleZoom`/`toggleLazygit`/`toggleSidebar` [on WindowController]/`overlayState`/`onOverlayStateChanged`/`shutdown`/`dismissTopOverlay`/`exitZoomIfNeeded`) are defined where introduced and consumed by `WindowController.handle`/dock. `KeyInterceptor.ReservedChord` cases added incrementally per task and routed in the same task. `DrawerEdge`, `OverlayState`, `FocusKind` defined before use.
- **Placeholder scan:** no `TODO`/`FIXME`; the "implementer designs X" notes give explicit requirements + sketched code, not deferred work.
- **Seam:** all new surfaces via `TerminalSurfaceFactory.make()` + `TerminalSurfaceConfig`; no SwiftTerm import in ZenTerm.
