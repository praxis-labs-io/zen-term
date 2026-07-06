# Epic 1 — Pane Canvas + Splits + Halo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A daily-drivable, splits-only terminal — create/close/navigate splits of independent live shells, with the iris focus halo tracking focus, splitting/closing never orphaning a process.

**Architecture:** A new pure `PaneKit` library holds the value-type `PaneNode` tree, pure tree ops, spatial-nav scoring, reconcile-diff, and the surface registry (all TDD'd). `ZenTerm` renders the tree with a recursive AppKit view hierarchy driven by a `PaneCanvasController`, reusing each leaf's `TerminalSurface` across restructures via the registry. Keybinds route through an extended `KeyInterceptor`; a new `NSMenu` frees `⌘H`.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, XCTest. `PaneKit` → `TerminalKit`; `ZenTerm` → `PaneKit` + `TerminalKit`. SwiftTerm stays behind `TerminalKit`.

## Global Constraints

- **Platform floor:** macOS 13 (`.macOS(.v13)`), Swift tools 5.9.
- **Seam (compile-enforced):** only `TerminalKit` may `import SwiftTerm`. `PaneKit` depends on `TerminalKit` for the `TerminalSurface` seam type but NOT on SwiftTerm (not a direct dep → cannot import it). `ZenTerm` imports no backend.
- **Module deps:** `PaneKit` depends on `TerminalKit`; `ZenTerm` depends on `PaneKit` + `TerminalKit`.
- **Colors:** canvas `#232136` = `NSColor(srgbRed: 0x23/255.0, green: 0x21/255.0, blue: 0x36/255.0, alpha: 1)`; panel border (unfocused) `NSColor(white: 1, alpha: 0.08)`; iris accent `#c4a7e7` = `NSColor(srgbRed: 0xc4/255.0, green: 0xa7/255.0, blue: 0xe7/255.0, alpha: 1)`. Pane corner radius `12`, gutter `12`.
- **Keybinds (provisional):** `⌘\` split vertical, `⌘-` split horizontal, `⌘h/j/k/l` spatial nav, `⌘W` close focused pane (last pane closes window). `⌘` chords never reach the PTY.
- **Menu:** own `NSApp.mainMenu`; Hide on `⌘⇧H`; do NOT bind `⌘H` (freed for nav-left); Quit `⌘Q`.
- **New-pane cwd:** inherit the focused pane's last-known cwd (OSC 7). **Min split size:** refuse a split when the focused pane is under `240`pt on the split axis.
- **Swift naming:** PascalCase types; one primary type per file; filename matches the type; `public` API in `PaneKit`/`TerminalKit`; no force-unwrap except documented AppKit `contentView!`.
- **Verified seam API (Epic 0):** `TerminalSurface { var view: NSView; var delegate: TerminalSurfaceDelegate?; var title: String; var isFocused: Bool; func start(_:); func focus(); func terminate(); func paste(_:); func copySelection() -> String?; func scrollToBottom() }`; `TerminalSurfaceConfig(command:args:workingDirectory:environment:fontSize:)`; `TerminalSurfaceFactory.make() -> TerminalSurface`; delegate `surface(_:cwdDidChange:)`, `surfaceDidExit(_:code:)`, `surface(_:titleDidChange:)`.

---

## File Structure

```text
Sources/
├── PaneKit/                       # NEW library target (depends on TerminalKit)
│   ├── PaneNode.swift             # PaneID, SplitID, SplitAxis, PaneNode
│   ├── PaneTree.swift             # PaneTree value + firstLeaf/leafIDs
│   ├── PaneTreeOps.swift          # splitting / closing / settingRatio
│   ├── SpatialNav.swift           # Direction + nearestLeaf scoring
│   ├── PaneDiff.swift             # paneDiff(from:to:)
│   └── PaneSurfaceRegistry.swift  # [PaneID: TerminalSurface] + apply(diff)
├── TerminalKit/ …                 # Epic 0 (unchanged)
└── ZenTerm/
    ├── PaneHostView.swift         # MODIFIED: leaf host, frame + halo, focus routing
    ├── SplitContainerView.swift   # NEW: recursive tree → AppKit layout
    ├── PaneCanvasController.swift  # NEW: owns tree+registry+cwd, renders, intents, surface delegate
    ├── AppDelegate.swift          # MODIFIED: use PaneCanvasController; install menu
    ├── KeyInterceptor.swift       # MODIFIED: reserved chords for split/close/nav
    ├── MainMenu.swift             # NEW: builds NSApp.mainMenu (frees ⌘H)
    └── … (HostWindow, main unchanged)
Tests/
└── PaneKitTests/                  # NEW test target
    ├── PaneTreeOpsTests.swift
    ├── SpatialNavTests.swift
    ├── PaneDiffTests.swift
    └── PaneSurfaceRegistryTests.swift
```

**Testability split:** all `PaneKit` logic (tree ops, nav, diff, registry identity) is unit-tested. `ZenTerm` AppKit rendering/focus/menu is verified by manual runbook (the app can't be `@testable`-imported and GUI behavior isn't meaningfully unit-testable).

**PR-sized tickets (Linear, ZenTerm team):**
- **PR 1 — PaneKit** (Tasks 1–6)
- **PR 2 — Tree-driven rendering** (Tasks 7–9)
- **PR 3 — Splits / close / focus / nav** (Tasks 10–11)
- **PR 4 — Main menu** (Task 12)

---

### Task 1: Scaffold `PaneKit` + `PaneKitTests`

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PaneKit/PaneNode.swift` (minimal stub to compile)
- Create: `Tests/PaneKitTests/PaneTreeOpsTests.swift` (trivial smoke test)

**Interfaces:**
- Produces: buildable `PaneKit` target (depends on `TerminalKit`), `PaneKitTests` target, and `ZenTerm` now depending on `PaneKit`.

- [ ] **Step 1: Add the targets to `Package.swift`**

In `Package.swift`, add `PaneKit` and `PaneKitTests` and add `PaneKit` to `ZenTerm`'s dependencies. The full `targets:` array becomes:

```swift
    targets: [
        .target(
            name: "TerminalKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .target(
            name: "PaneKit",
            dependencies: ["TerminalKit"]   // seam type only — NOT SwiftTerm
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: ["TerminalKit", "PaneKit"]  // still no SwiftTerm
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"]
        ),
        .testTarget(
            name: "PaneKitTests",
            dependencies: ["PaneKit"]
        ),
    ]
```

- [ ] **Step 2: Minimal stub so `PaneKit` compiles** (`Sources/PaneKit/PaneNode.swift`)

```swift
import Foundation

/// Identifies a terminal-hosting leaf pane. Values are supplied by the caller
/// (deterministic — no global mutable state in PaneKit).
public struct PaneID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}
```

- [ ] **Step 3: Trivial smoke test** (`Tests/PaneKitTests/PaneTreeOpsTests.swift`)

```swift
import XCTest
@testable import PaneKit

final class PaneTreeOpsTests: XCTestCase {
    func test_paneIDEquatable() {
        XCTAssertEqual(PaneID(1), PaneID(1))
        XCTAssertNotEqual(PaneID(1), PaneID(2))
    }
}
```

- [ ] **Step 4: Build + test**

Run: `swift build` then `swift test --filter PaneKitTests`
Expected: `Build complete!`; 1 test passes. (First build resolves nothing new — no new deps.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/PaneKit Tests/PaneKitTests
git commit -m "chore: scaffold PaneKit + PaneKitTests targets (ZEN)"
```

---

### Task 2: Pane tree types + traversal

**Files:**
- Modify: `Sources/PaneKit/PaneNode.swift`
- Create: `Sources/PaneKit/PaneTree.swift`
- Modify: `Tests/PaneKitTests/PaneTreeOpsTests.swift`

**Interfaces:**
- Produces:
  - `enum SplitAxis { case vertical, horizontal }`, `struct SplitID: Hashable`
  - `indirect enum PaneNode { case leaf(PaneID); case split(id: SplitID, axis: SplitAxis, ratio: Double, a: PaneNode, b: PaneNode) }`
  - `struct PaneTree { var root: PaneNode; var focusedLeaf: PaneID }`
  - `PaneNode.leafIDs -> [PaneID]`, `PaneNode.firstLeaf -> PaneID`, `PaneNode.contains(_ id: PaneID) -> Bool`

- [ ] **Step 1: Write the failing tests** (append to `PaneTreeOpsTests.swift`)

```swift
    func test_leafIDs_and_firstLeaf() {
        let tree = PaneNode.split(
            id: SplitID(1), axis: .vertical, ratio: 0.5,
            a: .leaf(PaneID(10)),
            b: .split(id: SplitID(2), axis: .horizontal, ratio: 0.5,
                      a: .leaf(PaneID(20)), b: .leaf(PaneID(30)))
        )
        XCTAssertEqual(tree.leafIDs, [PaneID(10), PaneID(20), PaneID(30)])
        XCTAssertEqual(tree.firstLeaf, PaneID(10))
        XCTAssertTrue(tree.contains(PaneID(30)))
        XCTAssertFalse(tree.contains(PaneID(99)))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneTreeOpsTests`
Expected: FAIL — `SplitID`, `PaneNode`, `.leafIDs` undefined.

- [ ] **Step 3: Extend `PaneNode.swift`**

Append to `Sources/PaneKit/PaneNode.swift`:

```swift
/// A split's identity (distinct from a leaf's).
public struct SplitID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}

/// Split orientation. `.vertical` = a | b side by side; `.horizontal` = a / b stacked.
public enum SplitAxis: Sendable { case vertical, horizontal }

/// The recursive pane layout for one window. A value type — all edits produce a new tree.
public indirect enum PaneNode: Sendable {
    case leaf(PaneID)
    case split(id: SplitID, axis: SplitAxis, ratio: Double, a: PaneNode, b: PaneNode)
}

public extension PaneNode {
    /// Leaf ids in left-to-right / a-before-b order.
    var leafIDs: [PaneID] {
        switch self {
        case let .leaf(id): return [id]
        case let .split(_, _, _, a, b): return a.leafIDs + b.leafIDs
        }
    }

    /// The first leaf reached by always descending into `a`.
    var firstLeaf: PaneID {
        switch self {
        case let .leaf(id): return id
        case let .split(_, _, _, a, _): return a.firstLeaf
        }
    }

    func contains(_ id: PaneID) -> Bool {
        leafIDs.contains(id)
    }
}
```

- [ ] **Step 4: Write `PaneTree.swift`**

```swift
import Foundation

/// The full pane state for one window: the layout tree plus which leaf is focused.
public struct PaneTree: Sendable {
    public var root: PaneNode
    public var focusedLeaf: PaneID

    public init(root: PaneNode, focusedLeaf: PaneID) {
        self.root = root
        self.focusedLeaf = focusedLeaf
    }

    /// A fresh single-leaf tree focused on that leaf.
    public init(singleLeaf id: PaneID) {
        self.root = .leaf(id)
        self.focusedLeaf = id
    }

    public var leafIDs: [PaneID] { root.leafIDs }
    public func contains(_ id: PaneID) -> Bool { root.contains(id) }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter PaneTreeOpsTests`
Expected: PASS — 2 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/PaneKit/PaneNode.swift Sources/PaneKit/PaneTree.swift Tests/PaneKitTests/PaneTreeOpsTests.swift
git commit -m "feat: PaneNode tree types + traversal (ZEN)"
```

---

### Task 3: Tree operations — split, close, setRatio

**Files:**
- Create: `Sources/PaneKit/PaneTreeOps.swift`
- Modify: `Tests/PaneKitTests/PaneTreeOpsTests.swift`

**Interfaces:**
- Consumes: `PaneTree`, `PaneNode`, `PaneID`, `SplitID`, `SplitAxis` (Task 2).
- Produces (methods on `PaneTree`):
  - `func splitting(_ leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneTree` — replaces `leaf` with `.split(a: leaf, b: newLeaf, ratio: 0.5)`; focus → `newLeaf`. If `leaf` absent, returns self unchanged.
  - `func closing(_ leaf: PaneID) -> PaneTree?` — removes `leaf`; collapses its parent split and promotes the sibling; focus → the sibling subtree's `firstLeaf` (or the old focus if a different leaf was focused). Returns `nil` iff `leaf` was the only leaf.
  - `func settingRatio(_ split: SplitID, to ratio: Double) -> PaneTree`.

- [ ] **Step 1: Write the failing tests** (append to `PaneTreeOpsTests.swift`)

```swift
    func test_splitting_replacesLeafWithSplit_focusMovesToNew() {
        let tree = PaneTree(singleLeaf: PaneID(1))
        let out = tree.splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertEqual(out.leafIDs, [PaneID(1), PaneID(2)])
        XCTAssertEqual(out.focusedLeaf, PaneID(2))
        guard case let .split(id, axis, ratio, a, b) = out.root else { return XCTFail("expected split") }
        XCTAssertEqual(id, SplitID(1)); XCTAssertEqual(axis, .vertical); XCTAssertEqual(ratio, 0.5)
        XCTAssertEqual(a.firstLeaf, PaneID(1)); XCTAssertEqual(b.firstLeaf, PaneID(2))
    }

    func test_splitting_absentLeaf_returnsUnchanged() {
        let tree = PaneTree(singleLeaf: PaneID(1))
        let out = tree.splitting(PaneID(99), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        XCTAssertEqual(out.leafIDs, [PaneID(1)])
    }

    func test_closing_promotesSibling_andCollapsesSplit() {
        // (1 | 2), focus 2 → close 2 → just leaf 1, focus 1.
        let split = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        let out = split.closing(PaneID(2))
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.leafIDs, [PaneID(1)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(1))
        if case .leaf = out!.root {} else { XCTFail("expected the sibling promoted to root leaf") }
    }

    func test_closing_deepSibling_keepsOtherPanes() {
        // 1 | (2 / 3): close 2 → 1 | 3, focus 3 (sibling firstLeaf).
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
            .splitting(PaneID(2), axis: .horizontal, newLeaf: PaneID(3), newSplit: SplitID(2))
        let out = tree.closing(PaneID(2))
        XCTAssertEqual(out?.leafIDs, [PaneID(1), PaneID(3)])
        XCTAssertEqual(out?.focusedLeaf, PaneID(3))
    }

    func test_closing_lastLeaf_returnsNil() {
        XCTAssertNil(PaneTree(singleLeaf: PaneID(1)).closing(PaneID(1)))
    }

    func test_closing_unfocusedLeaf_keepsFocusIfStillPresent() {
        // 1 | 2, focus 1, close 2 → leaf 1, focus stays 1.
        var tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        tree.focusedLeaf = PaneID(1)
        let out = tree.closing(PaneID(2))
        XCTAssertEqual(out?.focusedLeaf, PaneID(1))
    }

    func test_settingRatio() {
        let tree = PaneTree(singleLeaf: PaneID(1))
            .splitting(PaneID(1), axis: .vertical, newLeaf: PaneID(2), newSplit: SplitID(1))
        let out = tree.settingRatio(SplitID(1), to: 0.3)
        guard case let .split(_, _, ratio, _, _) = out.root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.3)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneTreeOpsTests`
Expected: FAIL — `splitting`, `closing`, `settingRatio` undefined.

- [ ] **Step 3: Write `PaneTreeOps.swift`**

```swift
import Foundation

public extension PaneTree {
    func splitting(_ leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneTree {
        guard let newRoot = PaneNode.split(node: root, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) else {
            return self
        }
        return PaneTree(root: newRoot, focusedLeaf: newLeaf)
    }

    func closing(_ leaf: PaneID) -> PaneTree? {
        guard root.contains(leaf) else { return self }
        guard let result = PaneNode.close(node: root, leaf: leaf) else {
            return nil // closed the only leaf
        }
        let newFocus: PaneID
        if leaf == focusedLeaf {
            newFocus = result.promotedFocus ?? result.node.firstLeaf
        } else {
            newFocus = result.node.contains(focusedLeaf) ? focusedLeaf : result.node.firstLeaf
        }
        return PaneTree(root: result.node, focusedLeaf: newFocus)
    }

    func settingRatio(_ split: SplitID, to ratio: Double) -> PaneTree {
        PaneTree(root: PaneNode.setRatio(node: root, split: split, ratio: ratio), focusedLeaf: focusedLeaf)
    }
}

extension PaneNode {
    /// Returns a new node with `leaf` replaced by a split of [leaf, newLeaf], or nil if `leaf` absent.
    static func split(node: PaneNode, at leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneNode? {
        switch node {
        case let .leaf(id):
            guard id == leaf else { return nil }
            return .split(id: newSplit, axis: axis, ratio: 0.5, a: .leaf(id), b: .leaf(newLeaf))
        case let .split(id, ax, ratio, a, b):
            if let na = split(node: a, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
                return .split(id: id, axis: ax, ratio: ratio, a: na, b: b)
            }
            if let nb = split(node: b, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
                return .split(id: id, axis: ax, ratio: ratio, a: a, b: nb)
            }
            return nil
        }
    }

    /// Result of a close: the new node (nil = whole subtree gone) and, when a split
    /// collapsed, the promoted sibling's firstLeaf (for focus).
    struct CloseResult { var node: PaneNode; var promotedFocus: PaneID? }

    static func close(node: PaneNode, leaf: PaneID) -> CloseResult? {
        switch node {
        case let .leaf(id):
            return id == leaf ? nil : CloseResult(node: node, promotedFocus: nil)
        case let .split(id, axis, ratio, a, b):
            if a.contains(leaf) {
                guard let r = close(node: a, leaf: leaf) else {
                    // a collapsed entirely → promote b
                    return CloseResult(node: b, promotedFocus: b.firstLeaf)
                }
                return CloseResult(node: .split(id: id, axis: axis, ratio: ratio, a: r.node, b: b),
                                   promotedFocus: r.promotedFocus)
            }
            if b.contains(leaf) {
                guard let r = close(node: b, leaf: leaf) else {
                    return CloseResult(node: a, promotedFocus: a.firstLeaf)
                }
                return CloseResult(node: .split(id: id, axis: axis, ratio: ratio, a: a, b: r.node),
                                   promotedFocus: r.promotedFocus)
            }
            return CloseResult(node: node, promotedFocus: nil)
        }
    }

    static func setRatio(node: PaneNode, split: SplitID, ratio: Double) -> PaneNode {
        switch node {
        case .leaf: return node
        case let .split(id, axis, r, a, b):
            if id == split { return .split(id: id, axis: axis, ratio: ratio, a: a, b: b) }
            return .split(id: id, axis: axis, ratio: r,
                          a: setRatio(node: a, split: split, ratio: ratio),
                          b: setRatio(node: b, split: split, ratio: ratio))
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter PaneTreeOpsTests`
Expected: PASS — all tree-op tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaneKit/PaneTreeOps.swift Tests/PaneKitTests/PaneTreeOpsTests.swift
git commit -m "feat: pane tree split/close/setRatio ops (ZEN)"
```

---

### Task 4: Spatial navigation

**Files:**
- Create: `Sources/PaneKit/SpatialNav.swift`
- Create: `Tests/PaneKitTests/SpatialNavTests.swift`

**Interfaces:**
- Produces: `enum Direction { case left, right, up, down }` and
  `func nearestLeaf(from: PaneID, frames: [PaneID: CGRect], direction: Direction) -> PaneID?`.
  Scoring (ported from prototype): candidate must lie in `direction` past a 4pt deadzone (compare center deltas); `score = primary + 2 * perpendicular`; lowest wins; nil if none qualify or `from` has no frame.

- [ ] **Step 1: Write the failing tests** (`Tests/PaneKitTests/SpatialNavTests.swift`)

```swift
import XCTest
import CoreGraphics
@testable import PaneKit

final class SpatialNavTests: XCTestCase {
    // Layout:  A | B   (side by side), C beneath A.
    //  A = (0,0,100,100)   B = (110,0,100,100)   C = (0,110,100,100)
    private let frames: [PaneID: CGRect] = [
        PaneID(1): CGRect(x: 0,   y: 0,   width: 100, height: 100), // A
        PaneID(2): CGRect(x: 110, y: 0,   width: 100, height: 100), // B
        PaneID(3): CGRect(x: 0,   y: 110, width: 100, height: 100), // C
    ]

    func test_right_fromA_findsB() {
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: frames, direction: .right), PaneID(2))
    }
    func test_left_fromB_findsA() {
        XCTAssertEqual(nearestLeaf(from: PaneID(2), frames: frames, direction: .left), PaneID(1))
    }
    func test_down_fromA_findsC() {
        XCTAssertEqual(nearestLeaf(from: PaneID(1), frames: frames, direction: .down), PaneID(3))
    }
    func test_up_fromA_findsNothing() {
        XCTAssertNil(nearestLeaf(from: PaneID(1), frames: frames, direction: .up))
    }
    func test_right_fromB_findsNothing() {
        XCTAssertNil(nearestLeaf(from: PaneID(2), frames: frames, direction: .right))
    }
    func test_unknownSource_returnsNil() {
        XCTAssertNil(nearestLeaf(from: PaneID(99), frames: frames, direction: .left))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SpatialNavTests`
Expected: FAIL — `Direction`, `nearestLeaf` undefined.

- [ ] **Step 3: Write `SpatialNav.swift`**

```swift
import CoreGraphics

public enum Direction: Sendable { case left, right, up, down }

/// Geometric nearest-neighbor pane navigation (ported from the prototype). Returns
/// the id of the closest pane in `direction`, or nil if none lies that way.
public func nearestLeaf(from: PaneID, frames: [PaneID: CGRect], direction: Direction) -> PaneID? {
    guard let src = frames[from] else { return nil }
    let fcx = src.midX, fcy = src.midY

    var best: (id: PaneID, score: CGFloat)?
    for (id, r) in frames where id != from {
        let dx = r.midX - fcx
        let dy = r.midY - fcy

        let primary: CGFloat
        let perp: CGFloat
        switch direction {
        case .left:  if dx >= -4 { continue }; primary = -dx; perp = abs(dy)
        case .right: if dx <=  4 { continue }; primary =  dx; perp = abs(dy)
        case .up:    if dy >= -4 { continue }; primary = -dy; perp = abs(dx)
        case .down:  if dy <=  4 { continue }; primary =  dy; perp = abs(dx)
        }
        let score = primary + perp * 2
        if best == nil || score < best!.score { best = (id, score) }
    }
    return best?.id
}
```

Note: this is coordinate-system agnostic — the caller supplies frames in ONE consistent space. In AppKit that space has y-up, so `.up` means increasing y; the caller (Task 10) passes frames in a top-left-origin flipped space (or negates) so `.up` visually means up. The unit test above uses a y-down layout (C beneath A has larger y), matching the flipped space the renderer will use.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter SpatialNavTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaneKit/SpatialNav.swift Tests/PaneKitTests/SpatialNavTests.swift
git commit -m "feat: spatial pane navigation scoring (ZEN)"
```

---

### Task 5: Reconcile-diff

**Files:**
- Create: `Sources/PaneKit/PaneDiff.swift`
- Create: `Tests/PaneKitTests/PaneDiffTests.swift`

**Interfaces:**
- Produces: `struct PaneDiff: Equatable { let created: [PaneID]; let removed: [PaneID]; let retained: [PaneID] }` and `func paneDiff(from old: [PaneID], to new: [PaneID]) -> PaneDiff`. `created` = in new not old; `removed` = in old not new; `retained` = in both. Each list in `new`/`old` order (deterministic).

- [ ] **Step 1: Write the failing tests** (`Tests/PaneKitTests/PaneDiffTests.swift`)

```swift
import XCTest
@testable import PaneKit

final class PaneDiffTests: XCTestCase {
    func test_split_addsOneCreated_retainsRest() {
        let d = paneDiff(from: [PaneID(1)], to: [PaneID(1), PaneID(2)])
        XCTAssertEqual(d.created, [PaneID(2)])
        XCTAssertEqual(d.removed, [])
        XCTAssertEqual(d.retained, [PaneID(1)])
    }
    func test_close_removesOne_retainsRest() {
        let d = paneDiff(from: [PaneID(1), PaneID(2)], to: [PaneID(1)])
        XCTAssertEqual(d.created, [])
        XCTAssertEqual(d.removed, [PaneID(2)])
        XCTAssertEqual(d.retained, [PaneID(1)])
    }
    func test_noChange_allRetained() {
        let d = paneDiff(from: [PaneID(1), PaneID(2)], to: [PaneID(1), PaneID(2)])
        XCTAssertEqual(d.created, [])
        XCTAssertEqual(d.removed, [])
        XCTAssertEqual(d.retained, [PaneID(1), PaneID(2)])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneDiffTests`
Expected: FAIL — `PaneDiff`, `paneDiff` undefined.

- [ ] **Step 3: Write `PaneDiff.swift`**

```swift
/// Which leaves were created, removed, or retained between two tree snapshots.
public struct PaneDiff: Equatable, Sendable {
    public let created: [PaneID]
    public let removed: [PaneID]
    public let retained: [PaneID]
}

public func paneDiff(from old: [PaneID], to new: [PaneID]) -> PaneDiff {
    let oldSet = Set(old), newSet = Set(new)
    return PaneDiff(
        created: new.filter { !oldSet.contains($0) },
        removed: old.filter { !newSet.contains($0) },
        retained: new.filter { oldSet.contains($0) }
    )
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter PaneDiffTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PaneKit/PaneDiff.swift Tests/PaneKitTests/PaneDiffTests.swift
git commit -m "feat: pane reconcile-diff (ZEN)"
```

---

### Task 6: `PaneSurfaceRegistry` (identity across restructure)

**Files:**
- Create: `Sources/PaneKit/PaneSurfaceRegistry.swift`
- Create: `Tests/PaneKitTests/PaneSurfaceRegistryTests.swift`

**Interfaces:**
- Consumes: `PaneDiff`, `PaneID` (Tasks 5, 2); `TerminalSurface` (TerminalKit seam).
- Produces: `final class PaneSurfaceRegistry` with `init(makeSurface: @escaping () -> TerminalSurface)`, `func surface(for: PaneID) -> TerminalSurface?`, `var ids: Set<PaneID>`, `@discardableResult func apply(_ diff: PaneDiff) -> [(id: PaneID, surface: TerminalSurface)]` (returns newly-created pairs so the caller can set delegate + start them; terminates removed; leaves retained untouched).

- [ ] **Step 1: Write the failing test** (`Tests/PaneKitTests/PaneSurfaceRegistryTests.swift`)

```swift
import XCTest
import AppKit
import TerminalKit
@testable import PaneKit

/// A seam-conforming fake with stable identity and a terminate flag.
private final class FakeSurface: NSObject, TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    var isFocused = false
    private(set) var terminated = false
    func start(_ config: TerminalSurfaceConfig) {}
    func focus() {}
    func terminate() { terminated = true }
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}

final class PaneSurfaceRegistryTests: XCTestCase {
    func test_retainedLeafKeepsSameSurfaceInstance_acrossSplitAndClose() {
        var made: [FakeSurface] = []
        let registry = PaneSurfaceRegistry(makeSurface: { let s = FakeSurface(); made.append(s); return s })

        // Split: create A.
        registry.apply(paneDiff(from: [], to: [PaneID(1)]))
        let a1 = registry.surface(for: PaneID(1))
        XCTAssertNotNil(a1)

        // Split again: create B, retain A. A must be the SAME instance.
        let created = registry.apply(paneDiff(from: [PaneID(1)], to: [PaneID(1), PaneID(2)]))
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.id, PaneID(2))
        XCTAssertTrue(registry.surface(for: PaneID(1)) === a1, "retained leaf's surface was recreated")

        // Close B: B terminated + removed, A untouched.
        let bSurface = registry.surface(for: PaneID(2)) as? FakeSurface
        registry.apply(paneDiff(from: [PaneID(1), PaneID(2)], to: [PaneID(1)]))
        XCTAssertNil(registry.surface(for: PaneID(2)))
        XCTAssertEqual(bSurface?.terminated, true)
        XCTAssertTrue(registry.surface(for: PaneID(1)) === a1)
        XCTAssertEqual(registry.ids, [PaneID(1)])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneSurfaceRegistryTests`
Expected: FAIL — `PaneSurfaceRegistry` undefined.

- [ ] **Step 3: Write `PaneSurfaceRegistry.swift`**

```swift
import TerminalKit

/// Owns the live `TerminalSurface` per leaf. Applying a diff creates surfaces for
/// new leaves (via the injected factory), terminates surfaces for removed leaves,
/// and leaves retained surfaces untouched — so a retained leaf keeps its running
/// shell, scrollback, and first-responder state across any tree restructure.
public final class PaneSurfaceRegistry {
    private var surfaces: [PaneID: TerminalSurface] = [:]
    private let makeSurface: () -> TerminalSurface

    public init(makeSurface: @escaping () -> TerminalSurface) {
        self.makeSurface = makeSurface
    }

    public func surface(for id: PaneID) -> TerminalSurface? { surfaces[id] }
    public var ids: Set<PaneID> { Set(surfaces.keys) }

    /// Applies the diff and returns the newly-created (id, surface) pairs so the
    /// caller can set their delegate and `start(...)` them with the right config.
    @discardableResult
    public func apply(_ diff: PaneDiff) -> [(id: PaneID, surface: TerminalSurface)] {
        for id in diff.removed {
            surfaces[id]?.terminate()
            surfaces[id] = nil
        }
        var created: [(id: PaneID, surface: TerminalSurface)] = []
        for id in diff.created {
            let surface = makeSurface()
            surfaces[id] = surface
            created.append((id, surface))
        }
        return created
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test`
Expected: PASS — all `PaneKitTests` (and Epic 0's `TerminalKitTests` still green).

- [ ] **Step 5: Commit**

```bash
git add Sources/PaneKit/PaneSurfaceRegistry.swift Tests/PaneKitTests/PaneSurfaceRegistryTests.swift
git commit -m "feat: PaneSurfaceRegistry preserves surfaces across restructure (ZEN)"
```

> **PR 1 boundary (PaneKit).** Tasks 1–6 form one PR-sized ticket. All logic is unit-tested; `swift build` + `swift test` green.

---

### Task 7: `PaneHostView` — leaf frame + halo + focus routing

**Files:**
- Modify (rewrite): `Sources/ZenTerm/PaneHostView.swift`

**Interfaces:**
- Consumes: `PaneID` (PaneKit).
- Produces: `final class PaneHostView: NSView` with
  `init(paneID: PaneID, content: NSView, onFocusRequest: @escaping (PaneID) -> Void)`,
  `var isFocused: Bool { get set }` (updates halo), and it routes `mouseDown` → `onFocusRequest(paneID)`.

- [ ] **Step 1: Rewrite `PaneHostView.swift`**

```swift
import AppKit
import PaneKit

/// Hosts one leaf's terminal surface: the rounded/bordered frame over the canvas,
/// plus the iris focus halo (accent border + soft glow) when focused. Clicking
/// anywhere in the pane requests focus for its leaf.
final class PaneHostView: NSView {
    let paneID: PaneID
    private let onFocusRequest: (PaneID) -> Void
    private let pane = NSView()

    var isFocused: Bool = false { didSet { updateHalo() } }

    init(paneID: PaneID, content: NSView, onFocusRequest: @escaping (PaneID) -> Void) {
        self.paneID = paneID
        self.onFocusRequest = onFocusRequest
        super.init(frame: .zero)

        wantsLayer = true
        pane.wantsLayer = true
        pane.layer?.cornerRadius = 12
        pane.layer?.masksToBounds = false          // glow must escape bounds; content clip is on a mask below
        pane.layer?.borderWidth = 1
        addSubview(pane)

        content.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView()                         // inner clip so terminal content stays inside the radius
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(clip)
        clip.addSubview(content)

        pane.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: topAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            clip.topAnchor.constraint(equalTo: pane.topAnchor),
            clip.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        updateHalo()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest(paneID)
        super.mouseDown(with: event)
    }

    private static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)
    private static let idleBorder = NSColor(white: 1, alpha: 0.08)

    private func updateHalo() {
        guard let layer = pane.layer else { return }
        if isFocused {
            layer.borderColor = Self.iris.cgColor
            layer.shadowColor = Self.iris.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 10
            layer.shadowOffset = .zero
        } else {
            layer.borderColor = Self.idleBorder.cgColor
            layer.shadowOpacity = 0
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` (PaneHostView's old Epic 0 initializer is replaced; Task 9 updates its caller — until then `AppDelegate` still references the old init and the build MAY fail. If so, that's expected and resolved in Task 9; to keep this task independently green, temporarily leave the old init in place is NOT allowed — instead this task is committed together with Task 9's caller update. See Step 3.)

- [ ] **Step 3: Commit (folded with Task 9)**

Because `AppDelegate` (Epic 0) constructs `PaneHostView(content:)` with the old signature, rewriting the initializer breaks that call. Do **not** commit Task 7 alone — implement Tasks 8–9 and commit the rendering stack together (Task 9 Step X), so the tree renderer replaces the old `AppDelegate` pane wiring in the same commit. Keep going.

---

### Task 8: `SplitContainerView` — recursive tree → layout

**Files:**
- Create: `Sources/ZenTerm/SplitContainerView.swift`

**Interfaces:**
- Consumes: `PaneNode`, `PaneID`, `SplitAxis` (PaneKit).
- Produces: `final class SplitContainerView: NSView` with
  `init(node: PaneNode, gutter: CGFloat = 12, leafView: (PaneID) -> NSView)` that builds the subview hierarchy for `node`: a `.leaf` installs `leafView(id)`; a `.split` lays out two child `SplitContainerView`s along the axis at the ratio with the gutter between them (fixed — no drag handle).

- [ ] **Step 1: Write `SplitContainerView.swift`**

```swift
import AppKit
import PaneKit

/// Recursively lays out a PaneNode: a leaf hosts its provided view; a split places
/// two child containers along its axis at the fixed ratio with a gutter gap.
final class SplitContainerView: NSView {
    init(node: PaneNode, gutter: CGFloat = 12, leafView: (PaneID) -> NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(node, gutter: gutter, leafView: leafView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build(_ node: PaneNode, gutter: CGFloat, leafView: (PaneID) -> NSView) {
        switch node {
        case let .leaf(id):
            let v = leafView(id)
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

        case let .split(_, axis, ratio, a, b):
            let first = SplitContainerView(node: a, gutter: gutter, leafView: leafView)
            let second = SplitContainerView(node: b, gutter: gutter, leafView: leafView)
            addSubview(first)
            addSubview(second)

            // Common cross-axis pinning + gutter along the split axis, with `first`
            // sized to `ratio` of the available space (minus half the gutter).
            if axis == .vertical {
                NSLayoutConstraint.activate([
                    first.leadingAnchor.constraint(equalTo: leadingAnchor),
                    first.topAnchor.constraint(equalTo: topAnchor),
                    first.bottomAnchor.constraint(equalTo: bottomAnchor),
                    second.trailingAnchor.constraint(equalTo: trailingAnchor),
                    second.topAnchor.constraint(equalTo: topAnchor),
                    second.bottomAnchor.constraint(equalTo: bottomAnchor),
                    second.leadingAnchor.constraint(equalTo: first.trailingAnchor, constant: gutter),
                    first.widthAnchor.constraint(equalTo: widthAnchor, multiplier: ratio, constant: -gutter / 2),
                ])
            } else {
                NSLayoutConstraint.activate([
                    first.leadingAnchor.constraint(equalTo: leadingAnchor),
                    first.trailingAnchor.constraint(equalTo: trailingAnchor),
                    first.topAnchor.constraint(equalTo: topAnchor),
                    second.leadingAnchor.constraint(equalTo: leadingAnchor),
                    second.trailingAnchor.constraint(equalTo: trailingAnchor),
                    second.bottomAnchor.constraint(equalTo: bottomAnchor),
                    second.topAnchor.constraint(equalTo: first.bottomAnchor, constant: gutter),
                    first.heightAnchor.constraint(equalTo: heightAnchor, multiplier: ratio, constant: -gutter / 2),
                ])
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: compiles the new file (may still fail on the Task 7 `AppDelegate` mismatch — resolved in Task 9). Do not commit alone.

---

### Task 9: `PaneCanvasController` + wire into `AppDelegate` (single pane, tree-backed)

**Files:**
- Create: `Sources/ZenTerm/PaneCanvasController.swift`
- Modify: `Sources/ZenTerm/AppDelegate.swift`

**Interfaces:**
- Consumes: `PaneTree`, `PaneSurfaceRegistry`, `paneDiff`, `TerminalSurfaceFactory`, `TerminalSurfaceConfig`, `PaneHostView`, `SplitContainerView`.
- Produces: `final class PaneCanvasController: NSObject` owning the tree + registry + per-leaf cwd, exposing `var canvasView: NSView` (the root the window hosts) and `func start()` (creates the first leaf). Conforms to `TerminalSurfaceDelegate` (routes cwd/exit for all panes). Focus + intents arrive in Tasks 10–11.

- [ ] **Step 1: Write `PaneCanvasController.swift`**

```swift
import AppKit
import PaneKit
import TerminalKit

/// Owns the pane tree, the surface registry, and per-leaf cwd. Renders the tree
/// into `canvasView`, reusing each leaf's surface across restructures. Acts as the
/// surface delegate for every pane.
final class PaneCanvasController: NSObject {
    let canvasView = NSView()

    private var tree: PaneTree
    private let registry: PaneSurfaceRegistry
    private var cwdByLeaf: [PaneID: URL] = [:]
    private var hostByLeaf: [PaneID: PaneHostView] = [:]
    private var nextID = 1

    private static let canvasColor = NSColor(srgbRed: 0x23 / 255.0, green: 0x21 / 255.0, blue: 0x36 / 255.0, alpha: 1)

    override init() {
        let firstLeaf = PaneID(1)
        self.tree = PaneTree(singleLeaf: firstLeaf)
        self.registry = PaneSurfaceRegistry(makeSurface: TerminalSurfaceFactory.make)
        super.init()
        nextID = 2
        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = Self.canvasColor.cgColor
    }

    private func mintPaneID() -> PaneID { defer { nextID += 1 }; return PaneID(nextID) }
    private func mintSplitID() -> SplitID { defer { nextID += 1 }; return SplitID(nextID) }

    /// Boots the first pane and renders.
    func start() {
        reconcileAndRender()
        focusFrontmost()
    }

    /// Diffs the registry against the current tree, creates/terminates surfaces,
    /// starts new ones (delegate + inherited cwd), then rebuilds the view tree.
    private func reconcileAndRender() {
        let diff = paneDiff(from: Array(registry.ids), to: tree.leafIDs)
        let created = registry.apply(diff)
        for (id, surface) in created {
            surface.delegate = self
            // Each created leaf starts with the cwd pre-seeded for it (nil → default
            // for the first pane; a split seeds the new leaf with its parent's cwd).
            surface.start(TerminalSurfaceConfig(workingDirectory: cwdByLeaf[id]))
        }
        for id in diff.removed { cwdByLeaf[id] = nil; hostByLeaf[id] = nil }
        rebuildViews()
    }

    private func rebuildViews() {
        canvasView.subviews.forEach { $0.removeFromSuperview() }
        hostByLeaf.removeAll(keepingCapacity: true)

        let root = SplitContainerView(node: tree.root, leafView: { [weak self] id in
            self?.hostView(for: id) ?? NSView()
        })
        // SplitContainerView.init already sets translatesAutoresizingMaskIntoConstraints=false.
        // 12pt gutter around the whole canvas (matches Epic 0's outer inset).
        canvasView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: canvasView.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: -12),
        ])
        updateHalo()
    }

    private func hostView(for id: PaneID) -> NSView {
        guard let surface = registry.surface(for: id) else { return NSView() }
        let host = PaneHostView(paneID: id, content: surface.view, onFocusRequest: { [weak self] pid in
            self?.focus(pid)
        })
        hostByLeaf[id] = host
        return host
    }

    private func updateHalo() {
        for (id, host) in hostByLeaf { host.isFocused = (id == tree.focusedLeaf) }
    }

    // Focus routing (fleshed out in Task 10).
    func focus(_ id: PaneID) {
        guard tree.contains(id) else { return }
        tree.focusedLeaf = id
        updateHalo()
        registry.surface(for: id)?.focus()
    }

    private func focusFrontmost() { focus(tree.focusedLeaf) }
}

extension PaneCanvasController: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        if let id = leafID(of: s) { cwdByLeaf[id] = url }
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        // Handled fully in Task 11 (close that leaf); for now, no-op keeps Epic-0 parity.
    }

    private func leafID(of surface: TerminalSurface) -> PaneID? {
        registry.ids.first { registry.surface(for: $0) === surface }
    }
}
```

- [ ] **Step 2: Rewrite `AppDelegate.applicationDidFinishLaunching` to host the controller**

Replace the whole `AppDelegate` body's window-content wiring. New `AppDelegate.swift`:

```swift
import AppKit
import TerminalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Set in applicationDidFinishLaunching before any code path can read it; a
    // documented AppKit force-unwrap, like contentView!.
    private var window: HostWindow!
    private let canvas = PaneCanvasController()
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560))
        let content = window.contentView!

        canvas.canvasView.frame = content.bounds
        canvas.canvasView.autoresizingMask = [.width, .height]
        content.addSubview(canvas.canvasView)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        canvas.start()

        keys.onReservedChord = { [weak self] chord in
            self?.handle(chord)
        }
        keys.start()
    }

    private func handle(_ chord: KeyInterceptor.ReservedChord) {
        // Split/close/nav wired in Task 11.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

(Note: this removes Epic 0's `ConsoleSurfaceLogger`-style wiring — the controller is now the surface delegate. `ConsoleSurfaceLogger` was already retired in Epic 0. The old `handle(_:)` is a stub filled in Task 11; `KeyInterceptor.ReservedChord` is extended in Task 11 — until then keep Epic 0's `.close`/`.logProbe` cases compiling by leaving `handle` a no-op that switches nothing. If the compiler warns about an unused `chord`, prefix with `_ = chord`.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Seam check**

Run: `grep -rn "import SwiftTerm" Sources/ZenTerm/ Sources/PaneKit/`
Expected: no output.

- [ ] **Step 5: Tests still green**

Run: `swift test`
Expected: all `PaneKitTests` + `TerminalKitTests` pass.

- [ ] **Step 6: Manual verification runbook**

Run: `swift run ZenTerm`
Confirm (should look identical to Epic 0, now tree-backed):
- One rounded/bordered pane with a 12pt gutter over the `#232136` canvas, holding a live login shell with your full env.
- The pane shows the iris halo (accent border + soft glow) — it's the focused (only) pane.
- Typing works; the terminal is first responder. `exit` quits (Epic 0 parity via the last-pane path arrives in Task 11 — for now `exit` may leave an empty window; that's acceptable at this checkpoint and fixed in Task 11).

- [ ] **Step 7: Commit (Tasks 7–9 together)**

```bash
git add Sources/ZenTerm/PaneHostView.swift Sources/ZenTerm/SplitContainerView.swift Sources/ZenTerm/PaneCanvasController.swift Sources/ZenTerm/AppDelegate.swift
git commit -m "feat: tree-backed single-pane rendering via PaneCanvasController (ZEN)"
```

> **PR 2 boundary (tree-driven rendering).** Tasks 7–9 form one PR-sized ticket. App renders the single pane through the tree/registry/view stack; halo shows; seam intact.

---

### Task 10: Focus routing + spatial navigation frames

**Files:**
- Modify: `Sources/ZenTerm/PaneCanvasController.swift`

**Interfaces:**
- Consumes: `nearestLeaf(from:frames:direction:)`, `Direction` (PaneKit).
- Produces: `func navigate(_ direction: Direction)` on the controller — reads current pane frames from `hostByLeaf`, calls `nearestLeaf`, focuses the result. `focus(_:)` already routes first responder + halo (Task 9).

- [ ] **Step 1: Add navigation to `PaneCanvasController`**

Add this method to `PaneCanvasController` (before the `TerminalSurfaceDelegate` extension):

```swift
    /// Move focus to the nearest pane in `direction`, using on-screen frames.
    func navigate(_ direction: Direction) {
        guard hostByLeaf.count > 1 else { return }
        // Frames in the canvas's coordinate space. AppKit is y-up; flip y so that
        // `.up` (smaller screen-y) maps to the smaller value the scorer expects.
        let h = canvasView.bounds.height
        var frames: [PaneID: CGRect] = [:]
        for (id, host) in hostByLeaf {
            let f = host.convert(host.bounds, to: canvasView)
            frames[id] = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
        }
        if let target = nearestLeaf(from: tree.focusedLeaf, frames: frames, direction: direction) {
            focus(target)
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` (no caller yet — Task 11 wires the keybinds; `navigate` is unused for now, which is fine — it's `internal` and called next task).

- [ ] **Step 3: Commit**

```bash
git add Sources/ZenTerm/PaneCanvasController.swift
git commit -m "feat: spatial navigate() over live pane frames (ZEN)"
```

---

### Task 11: Split / close intents + keybinds

**Files:**
- Modify: `Sources/ZenTerm/KeyInterceptor.swift`
- Modify: `Sources/ZenTerm/PaneCanvasController.swift`
- Modify: `Sources/ZenTerm/AppDelegate.swift`

**Interfaces:**
- Produces: extended `KeyInterceptor.ReservedChord` = `{ splitVertical, splitHorizontal, navLeft, navRight, navUp, navDown, closePane }`; controller intents `func split(_ axis: SplitAxis)`, `func closeFocused() -> Bool` (returns false when the last pane closed → window should close); `AppDelegate.handle` routes chords.

- [ ] **Step 1: Extend `KeyInterceptor`**

Rewrite the reserved-allowlist section of `Sources/ZenTerm/KeyInterceptor.swift`. Replace the `enum ReservedChord` and the monitor's matching block:

```swift
    enum ReservedChord {
        case splitVertical, splitHorizontal
        case navLeft, navRight, navUp, navDown
        case closePane
    }

    func start() {
        stop() // idempotent: never stack a second monitor on repeat calls
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command else { return event }   // only bare ⌘ chords are reserved
            let key = event.charactersIgnoringModifiers?.lowercased()

            let chord: ReservedChord?
            switch key {
            case "\\": chord = .splitVertical
            case "-":  chord = .splitHorizontal
            case "h":  chord = .navLeft
            case "l":  chord = .navRight
            case "k":  chord = .navUp
            case "j":  chord = .navDown
            case "w":  chord = .closePane
            default:   chord = nil
            }
            if let chord {
                self.onReservedChord?(chord)
                return nil                                   // consumed — never reaches the PTY
            }
            return event                                     // everything else passes through
        }
    }
```

(Leave `stop()` and `deinit` as they are from Epic 0.)

- [ ] **Step 2: Add split/close intents to `PaneCanvasController`**

Add to `PaneCanvasController` (near `navigate`):

```swift
    private static let minSplitExtent: CGFloat = 240

    /// Split the focused pane along `axis`, unless it is too small to halve usefully.
    func split(_ axis: SplitAxis) {
        guard let host = hostByLeaf[tree.focusedLeaf] else { return }
        let size = host.bounds.size
        let extent = (axis == .vertical) ? size.width : size.height
        guard extent >= Self.minSplitExtent else { NSSound.beep(); return }

        let source = tree.focusedLeaf
        let newLeaf = mintPaneID()
        cwdByLeaf[newLeaf] = cwdByLeaf[source]   // inherit the focused pane's cwd
        tree = tree.splitting(source, axis: axis, newLeaf: newLeaf, newSplit: mintSplitID())
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
    }

    /// Close the focused pane. Returns false when it was the last pane (caller closes the window).
    @discardableResult
    func closeFocused() -> Bool {
        guard let next = tree.closing(tree.focusedLeaf) else { return false }
        tree = next
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
        return true
    }
```

- [ ] **Step 3: Handle a leaf's own shell exit as a close**

Replace the `surfaceDidExit` stub in the delegate extension:

```swift
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        guard let id = leafID(of: s) else { return }
        guard let next = tree.closing(id) else {
            onLastPaneClosed?()      // last pane's shell exited → close window
            return
        }
        tree = next
        reconcileAndRender()
        registry.surface(for: tree.focusedLeaf)?.focus()
    }
```

And add the callback property near the top of `PaneCanvasController`:

```swift
    /// Invoked when the final pane goes away (last close or last shell exit).
    var onLastPaneClosed: (() -> Void)?
```

- [ ] **Step 4: Route chords in `AppDelegate`**

Replace `AppDelegate.handle` and wire `onLastPaneClosed` in `applicationDidFinishLaunching` (after `canvas.start()`):

```swift
        canvas.onLastPaneClosed = { [weak self] in self?.window.close() }
```

```swift
    private func handle(_ chord: KeyInterceptor.ReservedChord) {
        switch chord {
        case .splitVertical:   canvas.split(.vertical)
        case .splitHorizontal: canvas.split(.horizontal)
        case .navLeft:  canvas.navigate(.left)
        case .navRight: canvas.navigate(.right)
        case .navUp:    canvas.navigate(.up)
        case .navDown:  canvas.navigate(.down)
        case .closePane:
            if canvas.closeFocused() == false { window.close() }
        }
    }
```

- [ ] **Step 5: Build + tests**

Run: `swift build && swift test`
Expected: `Build complete!`; all tests green.

- [ ] **Step 6: Seam check**

Run: `grep -rn "import SwiftTerm" Sources/ZenTerm/ Sources/PaneKit/`
Expected: no output.

- [ ] **Step 7: Manual verification runbook**

Run: `swift run ZenTerm`
Confirm:
- `⌘\` splits the focused pane **vertically** (side by side); `⌘-` splits **horizontally** (stacked). Gutter shows between panes; each new pane is a live shell.
- The new pane inherits the focused pane's cwd: `cd /tmp` in a pane, then `⌘\` — the new pane's prompt is in `/tmp`.
- `⌘h/j/k/l` moves focus spatially; the halo follows; the focused pane receives typing.
- Click a pane → it focuses (halo moves).
- `⌘W` closes the focused pane; a sibling is promoted and focused. Closing the **last** pane closes the window (app quits).
- `exit` inside a pane closes that pane (promotes sibling); `exit` in the last pane quits.
- Split a pane down to near-minimum, then `⌘\` again on a narrow pane → refused with a beep (no split under ~240pt).
- `Ctrl+H` in a shell still deletes a char (⌘ chords consumed, Ctrl passes through).

- [ ] **Step 8: Commit**

```bash
git add Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/PaneCanvasController.swift Sources/ZenTerm/AppDelegate.swift
git commit -m "feat: split/close/navigate keybinds and intents (ZEN)"
```

> **PR 3 boundary (splits/close/focus/nav).** Tasks 10–11 form one PR-sized ticket. Splits, close, spatial nav, click-focus, halo, cwd inheritance, and min-size refusal all work.

---

### Task 12: Main menu — free `⌘H`

**Files:**
- Create: `Sources/ZenTerm/MainMenu.swift`
- Modify: `Sources/ZenTerm/AppDelegate.swift`

**Interfaces:**
- Produces: `enum MainMenu { static func install(copyPaste target: AnyObject?) }` building `NSApp.mainMenu` with an App menu (About, Hide on `⌘⇧H`, Quit `⌘Q`) and an Edit menu (Copy `⌘C`, Paste `⌘V` targeting the controller). `⌘H` is deliberately unbound.

- [ ] **Step 1: Write `MainMenu.swift`**

```swift
import AppKit

/// Builds zen-term's main menu. Critically, Hide is bound to ⌘⇧H (NOT ⌘H), so
/// ⌘H is free for pane-nav-left. Copy/Paste route to `copyPaste` target's
/// @objc copyFromSurface: / pasteToSurface: actions.
enum MainMenu {
    static func install(copyPaste target: AnyObject?) {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About zen-term", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide zen-term", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command, .shift]   // ⌘⇧H — frees ⌘H
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit zen-term", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (Copy/Paste to the focused surface)
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        let copy = NSMenuItem(title: "Copy", action: Selector(("copyFromSurface:")), keyEquivalent: "c")
        copy.target = target
        editMenu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: Selector(("pasteToSurface:")), keyEquivalent: "v")
        paste.target = target
        editMenu.addItem(paste)

        NSApp.mainMenu = main
    }
}
```

- [ ] **Step 2: Add Copy/Paste actions to `PaneCanvasController`**

Add to `PaneCanvasController`:

```swift
    @objc func copyFromSurface(_ sender: Any?) {
        guard let text = registry.surface(for: tree.focusedLeaf)?.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func pasteToSurface(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        registry.surface(for: tree.focusedLeaf)?.paste(text)
    }
```

- [ ] **Step 3: Install the menu in `AppDelegate`**

In `applicationDidFinishLaunching`, before `window.makeKeyAndOrderFront(nil)`:

```swift
        MainMenu.install(copyPaste: canvas)
```

- [ ] **Step 4: Build + tests**

Run: `swift build && swift test`
Expected: `Build complete!`; tests green.

- [ ] **Step 5: Manual verification runbook**

Run: `swift run ZenTerm`
Confirm:
- A menu bar shows "zen-term" with About / Hide / Quit and an Edit menu with Copy / Paste.
- **`⌘H` navigates focus left** (does NOT hide the app). **`⌘⇧H` hides** the app (⌘Tab back).
- `⌘Q` quits. Select text in a pane, `⌘C`, then `⌘V` in another pane pastes it.
- All Task 11 behaviors still work.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZenTerm/MainMenu.swift Sources/ZenTerm/AppDelegate.swift Sources/ZenTerm/PaneCanvasController.swift
git commit -m "feat: main menu; free ⌘H for nav (Hide → ⌘⇧H) (ZEN)"
```

> **PR 4 boundary (main menu).** Task 12 is one PR-sized ticket. `⌘H` is freed; menu + Copy/Paste land.

---

## Definition of Done (Epic 1)

- [ ] Create (`⌘\` / `⌘-`), close (`⌘W`), and navigate (`⌘hjkl` + click) splits; focus routing correct across all panes. (Tasks 10–11)
- [ ] The halo marks exactly the focused pane at all times. (Tasks 7, 9–11)
- [ ] Every pane is an independent live shell via `TerminalSurfaceFactory.make()`. (Tasks 6, 9)
- [ ] Splitting/closing never orphans or recreates a running process — registry identity holds. (Task 6 test + Tasks 9, 11)
- [ ] Last pane close (chord or shell exit) closes the window; single-pane == Epic 0. (Task 11)
- [ ] New panes inherit the focused pane's cwd; splits under ~240pt refused. (Tasks 9, 11)
- [ ] `⌘H` navigates left (Hide on `⌘⇧H`); menu installed. (Task 12)
- [ ] Seam intact (`ZenTerm`/`PaneKit` import no backend); `swift build` clean; `PaneKitTests` + `TerminalKitTests` green. (all)

## Self-Review Notes

- **Spec coverage:** model → T2–T3; nav → T4; diff → T5; registry identity → T6; view tree → T7–T8; controller/render/cwd/delegate → T9; focus+nav → T9–T10; keybinds+split/close+min-size+last-pane → T11; halo → T7/T9; menu+⌘H → T12.
- **Type consistency:** `PaneID`/`SplitID`/`SplitAxis`/`PaneNode`/`PaneTree`, `splitting`/`closing`/`settingRatio`, `nearestLeaf`, `paneDiff`/`PaneDiff`, `PaneSurfaceRegistry.apply`, `PaneCanvasController.split/closeFocused/navigate/focus`, `KeyInterceptor.ReservedChord` used identically across tasks.
- **Known execution-time checks:** Task 7's `PaneHostView` init break is intentionally resolved by committing Tasks 7–9 together (flagged in T7/T8 "do not commit alone"). The AppKit constraint-based ratio layout (T8) is verified live in T9/T11 runbooks, not unit-tested.
