# Epic 2 — Tabs + windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multiply Epic 1's per-window pane tree into in-window numbered tabs and real multi-window, with background-tab shells staying alive.

**Architecture:** A tab *is* an Epic-1 `PaneCanvasController`. A new pure `TabKit` target holds tab ordering/active-index bookkeeping; a `WindowController` swaps which tab's `canvasView` is mounted and renders a bottom-left numbered `TabBarView`; `AppDelegate` becomes a window manager routing chords to the key window. No `PaneKit` or seam changes.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit. New library target `TabKit` (pure, no AppKit/SwiftTerm, tested like `PaneKit`).

## Global Constraints

- **The seam is inviolate.** `TabKit` is pure Swift — no `import AppKit`, no `import SwiftTerm`. Only `Sources/TerminalKit` may import SwiftTerm. `Sources/ZenTerm` imports `TerminalKit`, `PaneKit`, `TabKit` only.
- **Swift conventions:** PascalCase types; one primary type per file; filename matches the type. Public API in `TabKit` is `public`. Prefer `struct` / `final class`. No force-unwrap except documented AppKit (`contentView!`).
- **No defer markers** (`TODO`/`FIXME`/`HACK`) and no suppressions — fix now or file a Linear ticket.
- **Verify before done:** `swift build` clean **and** `swift test` green. AppKit behavior with no unit test is verified by `swift run ZenTerm` against the task's manual runbook.
- **Keybinds are bare-⌘ chords** intercepted by `KeyInterceptor`; un-reserved chords pass through to the PTY untouched (the Ctrl+hjkl / nvim rule).
- **cwd inheritance rule:** new tab inherits the current tab's focused-pane cwd; new window inherits the key window's focused-pane cwd.
- **Iris accent** is `NSColor(srgbRed: 0xc4/255, green: 0xa7/255, blue: 0xe7/255, alpha: 1)` (matches the Epic 1 halo).

---

## PR 1 — TabKit + pure tab model

### Task 1: `TabKit` target with `TabID` + `TabList`

**Files:**
- Modify: `Package.swift` (add `TabKit` target + `TabKitTests` test target; add `TabKit` to the `ZenTerm` target deps)
- Create: `Sources/TabKit/TabID.swift`
- Create: `Sources/TabKit/TabList.swift`
- Test: `Tests/TabKitTests/TabListTests.swift`

**Interfaces:**
- Produces:
  - `public struct TabID: Hashable, Sendable { public let raw: Int; public init(_ raw: Int) }`
  - `public struct TabList` with:
    - `public init(first: TabID)`
    - `public private(set) var order: [TabID]`
    - `public private(set) var activeIndex: Int`
    - `public var activeID: TabID { get }`
    - `public mutating func add(_ id: TabID)`
    - `public mutating func select(_ id: TabID)`
    - `public mutating func select(index: Int)`
    - `@discardableResult public mutating func close(_ id: TabID) -> Bool` (returns `false` iff the list is now empty)

- [ ] **Step 1: Add the `TabKit` and `TabKitTests` targets to `Package.swift`**

In the `targets:` array, add `TabKit` after the `PaneKit` target and `TabKitTests` after `PaneKitTests`, and add `"TabKit"` to the `ZenTerm` executable target's dependencies. Final `targets` array:

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
        .target(
            name: "TabKit"                   // pure — no AppKit, no SwiftTerm
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: ["TerminalKit", "PaneKit", "TabKit"]  // still no SwiftTerm
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"]
        ),
        .testTarget(
            name: "PaneKitTests",
            dependencies: ["PaneKit", "TerminalKit"]
        ),
        .testTarget(
            name: "TabKitTests",
            dependencies: ["TabKit"]
        ),
    ]
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/TabKitTests/TabListTests.swift`:

```swift
import XCTest
@testable import TabKit

final class TabListTests: XCTestCase {
    func test_tabIDEquatable() {
        XCTAssertEqual(TabID(1), TabID(1))
        XCTAssertNotEqual(TabID(1), TabID(2))
    }

    func test_init_singleActiveTab() {
        let list = TabList(first: TabID(1))
        XCTAssertEqual(list.order, [TabID(1)])
        XCTAssertEqual(list.activeIndex, 0)
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_add_appendsAndActivates() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
        XCTAssertEqual(list.activeID, TabID(2))
    }

    func test_select_presentAndAbsent() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.select(TabID(1))
        XCTAssertEqual(list.activeID, TabID(1))
        list.select(TabID(99))                 // absent → no-op
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_selectByIndex_clamps() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        list.select(index: 99)
        XCTAssertEqual(list.activeID, TabID(3))
        list.select(index: -5)
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_close_nonActiveLeft_shiftsActiveIndex() {
        // [1,2,3] active=3(idx2). Close 1 → [2,3], active still 3.
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        XCTAssertTrue(list.close(TabID(1)))
        XCTAssertEqual(list.order, [TabID(2), TabID(3)])
        XCTAssertEqual(list.activeID, TabID(3))
    }

    func test_close_active_promotesRightNeighbor() {
        // [1,2,3] active=2(idx1). Close 2 → [1,3], active=3 (the right neighbor).
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        list.select(TabID(2))
        XCTAssertTrue(list.close(TabID(2)))
        XCTAssertEqual(list.order, [TabID(1), TabID(3)])
        XCTAssertEqual(list.activeID, TabID(3))
    }

    func test_close_activeRightmost_clampsToNewLast() {
        // [1,2,3] active=3(idx2). Close 3 → [1,2], active=2 (clamped).
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        XCTAssertTrue(list.close(TabID(3)))
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
        XCTAssertEqual(list.activeID, TabID(2))
    }

    func test_close_lastTab_returnsFalse() {
        var list = TabList(first: TabID(1))
        XCTAssertFalse(list.close(TabID(1)))
        XCTAssertTrue(list.order.isEmpty)
    }

    func test_close_absent_isNoOpReturnsTrue() {
        var list = TabList(first: TabID(1))
        XCTAssertTrue(list.close(TabID(99)))
        XCTAssertEqual(list.order, [TabID(1)])
        XCTAssertEqual(list.activeID, TabID(1))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter TabListTests`
Expected: FAIL — `TabKit` / `TabID` / `TabList` not found (targets/types don't exist yet).

- [ ] **Step 4: Create `TabID`**

Create `Sources/TabKit/TabID.swift`:

```swift
/// Identifies a tab within one window. Values are supplied by the caller
/// (deterministic — no global mutable state in TabKit), like PaneID.
public struct TabID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}
```

- [ ] **Step 5: Create `TabList`**

Create `Sources/TabKit/TabList.swift`:

```swift
/// The ordered set of tabs in one window plus which is active. A value type —
/// pure ordering/active-index bookkeeping, no view or process state. The window
/// chrome keeps a parallel `[TabID: controller]` dict keyed by id, so ordering and
/// active live only here.
public struct TabList {
    public private(set) var order: [TabID]
    public private(set) var activeIndex: Int

    public init(first: TabID) {
        order = [first]
        activeIndex = 0
    }

    public var activeID: TabID { order[activeIndex] }

    /// Append a tab and make it active.
    public mutating func add(_ id: TabID) {
        order.append(id)
        activeIndex = order.count - 1
    }

    /// Make `id` active if present; no-op otherwise.
    public mutating func select(_ id: TabID) {
        guard let idx = order.firstIndex(of: id) else { return }
        activeIndex = idx
    }

    /// Make the tab at `index` active, clamped into range.
    public mutating func select(index: Int) {
        guard !order.isEmpty else { return }
        activeIndex = min(max(index, 0), order.count - 1)
    }

    /// Remove `id`. Returns `false` iff the list is now empty (caller closes the
    /// window). When the active tab is closed, its right neighbor becomes active
    /// (clamped to the new last tab if it was rightmost).
    @discardableResult
    public mutating func close(_ id: TabID) -> Bool {
        guard let idx = order.firstIndex(of: id) else { return true }
        order.remove(at: idx)
        if order.isEmpty { activeIndex = 0; return false }
        if idx < activeIndex {
            activeIndex -= 1
        } else if idx == activeIndex {
            activeIndex = min(idx, order.count - 1)
        }
        return true
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter TabListTests`
Expected: PASS (10 tests). Then `swift build` clean and full `swift test` green.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/TabKit Tests/TabKitTests
git commit -m "feat(tabkit): pure TabList model for tab ordering + active index"
```

---

## PR 2 — In-window tabs

Ship PR 1 first (merge). Branch PR 2 from the ticket's Linear `gitBranchName`.

### Task 2: `PaneCanvasController` additions — `initialCWD`, title signal

**Files:**
- Modify: `Sources/ZenTerm/PaneCanvasController.swift`

**Interfaces:**
- Consumes: existing `PaneCanvasController` (Epic 1) — `canvasView`, `start()`, `focus(_:)`, `split(_:)`, `closeFocused() -> Bool`, `onLastPaneClosed`, `cwdByLeaf`, `tree`.
- Produces:
  - `init(initialCWD: URL?)` — seeds the first pane's cwd (default `nil` → login-shell default). The existing `init()` becomes `init(initialCWD: URL? = nil)`.
  - `var title: String` — focused leaf's cwd basename, fallback `"~"`.
  - `var focusedCWD: URL?` — the focused leaf's cwd (for new-tab/window inheritance).
  - `var onTitleChanged: (() -> Void)?` — fired when the focused pane's cwd changes or focus moves.

- [ ] **Step 1: Seed the first pane's cwd via `init(initialCWD:)`**

Replace the `override init()` signature and body head so the first leaf's cwd is seeded. Change:

```swift
    override init() {
        let firstLeaf = PaneID(1)
        self.tree = PaneTree(singleLeaf: firstLeaf)
        self.registry = PaneSurfaceRegistry(makeSurface: TerminalSurfaceFactory.make)
        super.init()
        nextID = 2
```

to:

```swift
    init(initialCWD: URL? = nil) {
        let firstLeaf = PaneID(1)
        self.tree = PaneTree(singleLeaf: firstLeaf)
        self.registry = PaneSurfaceRegistry(makeSurface: TerminalSurfaceFactory.make)
        super.init()
        nextID = 2
        if let initialCWD { cwdByLeaf[firstLeaf] = initialCWD }
```

(Keep the remaining `canvasView.wantsLayer` / background lines unchanged.)

- [ ] **Step 2: Add the title + focusedCWD computed properties and the signal**

Add near the top of the type (after `var onLastPaneClosed`):

```swift
    /// Fired when the tab's title may have changed — the focused pane's cwd
    /// changed, or focus moved to a different pane.
    var onTitleChanged: (() -> Void)?

    /// The focused pane's cwd, for new-tab / new-window inheritance.
    var focusedCWD: URL? { cwdByLeaf[tree.focusedLeaf] }

    /// The tab's display title: the focused pane's cwd basename, or "~".
    var title: String {
        guard let url = cwdByLeaf[tree.focusedLeaf] else { return "~" }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? "~" : name
    }
```

- [ ] **Step 3: Fire `onTitleChanged` when focus moves**

In `func focus(_ id:)`, after `updateHalo()`, add the title signal. The method becomes:

```swift
    func focus(_ id: PaneID) {
        guard tree.contains(id) else { return }
        tree.focusedLeaf = id
        updateHalo()
        onTitleChanged?()
        registry.surface(for: id)?.focus()
    }
```

- [ ] **Step 4: Fire `onTitleChanged` when the focused pane's cwd changes**

In the `TerminalSurfaceDelegate` extension's `surface(_:cwdDidChange:)`, fire the signal only when the change is on the focused pane (a background pane's cwd change doesn't alter the title). Replace:

```swift
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        if let id = leafID(of: s) { cwdByLeaf[id] = url }
    }
```

with:

```swift
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {
        guard let id = leafID(of: s) else { return }
        cwdByLeaf[id] = url
        if id == tree.focusedLeaf { onTitleChanged?() }
    }
```

- [ ] **Step 5: Verify build**

Run: `swift build`
Expected: clean. (No unit test — these are AppKit-coupled reads of private `cwdByLeaf`; exercised behaviorally in Task 4's runbook.)

- [ ] **Step 6: Commit**

```bash
git add Sources/ZenTerm/PaneCanvasController.swift
git commit -m "feat(chrome): PaneCanvasController exposes title + initialCWD for tabs"
```

### Task 3: `TabBarView` — numbered bottom-left bar

**Files:**
- Create: `Sources/ZenTerm/TabBarView.swift`

**Interfaces:**
- Produces:
  - `struct TabBarItem { let id: TabID; let index: Int; let title: String; let isActive: Bool }`
  - `final class TabBarView: NSView` with:
    - `init(onSelect: @escaping (TabID) -> Void, onClose: @escaping (TabID) -> Void, onNewTab: @escaping () -> Void)`
    - `func render(_ items: [TabBarItem])` — rebuilds the bar from a snapshot
    - `static let height: CGFloat = 28`

- [ ] **Step 1: Create the view**

Create `Sources/ZenTerm/TabBarView.swift`. A pure view: no model state beyond the last snapshot; all mutation flows through the three callbacks. Numbered mono labels, iris underline under the active tab, a trailing `+`. Middle-click a tab closes it; a hover `×` is out of scope for v1 (keyboard `⌘w` + middle-click cover close — the prototype's hover-× is deferred to keep this a plain bar).

```swift
import AppKit
import TabKit

struct TabBarItem {
    let id: TabID
    let index: Int      // 1-based number shown before the title
    let title: String
    let isActive: Bool
}

/// The bottom-left numbered tab bar. Stateless beyond its last rendered snapshot;
/// selection/close/new all flow out through callbacks. Clicking a tab selects it;
/// middle-clicking a tab closes it; the trailing "+" makes a new tab.
final class TabBarView: NSView {
    private let onSelect: (TabID) -> Void
    private let onClose: (TabID) -> Void
    private let onNewTab: () -> Void

    static let height: CGFloat = 28

    private static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)
    private static let activeInk = NSColor(white: 0.92, alpha: 1)
    private static let idleInk = NSColor(white: 0.92, alpha: 0.5)
    private static let numberInk = NSColor(white: 0.92, alpha: 0.35)

    private let stack = NSStackView()

    init(onSelect: @escaping (TabID) -> Void,
         onClose: @escaping (TabID) -> Void,
         onNewTab: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTab = onNewTab
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ items: [TabBarItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            stack.addArrangedSubview(TabButton(item: item,
                                               onSelect: onSelect,
                                               onClose: onClose))
        }
        let plus = NSButton(title: "+", target: self, action: #selector(newTabTapped))
        plus.isBordered = false
        plus.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        plus.contentTintColor = Self.idleInk
        stack.addArrangedSubview(plus)
    }

    @objc private func newTabTapped() { onNewTab() }

    /// One tab entry: `N title` with an iris underline when active.
    private final class TabButton: NSView {
        private let id: TabID
        private let onSelect: (TabID) -> Void
        private let onClose: (TabID) -> Void
        private let underline = NSView()

        init(item: TabBarItem, onSelect: @escaping (TabID) -> Void, onClose: @escaping (TabID) -> Void) {
            self.id = item.id
            self.onSelect = onSelect
            self.onClose = onClose
            super.init(frame: .zero)
            wantsLayer = true

            let label = NSTextField(labelWithAttributedString: Self.attributed(item))
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            underline.wantsLayer = true
            underline.layer?.backgroundColor = TabBarView.iris.cgColor
            underline.isHidden = !item.isActive
            underline.translatesAutoresizingMaskIntoConstraints = false
            addSubview(underline)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                underline.leadingAnchor.constraint(equalTo: leadingAnchor),
                underline.trailingAnchor.constraint(equalTo: trailingAnchor),
                underline.bottomAnchor.constraint(equalTo: bottomAnchor),
                underline.heightAnchor.constraint(equalToConstant: 2),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private static func attributed(_ item: TabBarItem) -> NSAttributedString {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            let ink = item.isActive ? TabBarView.activeInk : TabBarView.idleInk
            let s = NSMutableAttributedString(
                string: "\(item.index) ",
                attributes: [.font: font, .foregroundColor: TabBarView.numberInk])
            s.append(NSAttributedString(
                string: item.title,
                attributes: [.font: font, .foregroundColor: ink,
                             .kern: 0.5]))
            return s
        }

        override func mouseDown(with event: NSEvent) { onSelect(id) }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onClose(id) }   // middle-click closes
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: clean. (AppKit view — verified behaviorally in Task 4's runbook.)

- [ ] **Step 3: Commit**

```bash
git add Sources/ZenTerm/TabBarView.swift
git commit -m "feat(chrome): numbered bottom-left TabBarView"
```

### Task 4: `WindowController` — compose tabs, view-swap, keybinds, cascade

**Files:**
- Create: `Sources/ZenTerm/Tab.swift`
- Create: `Sources/ZenTerm/WindowController.swift`
- Modify: `Sources/ZenTerm/KeyInterceptor.swift` (add tab chords)
- Modify: `Sources/ZenTerm/AppDelegate.swift` (delegate to a single `WindowController`)

**Interfaces:**
- Consumes: `PaneCanvasController(initialCWD:)`, `.title`, `.focusedCWD`, `.onTitleChanged`, `.onLastPaneClosed`, `.canvasView`, `.start()`, `.split(_:)`, `.navigate(_:)`, `.closeFocused()`, `.copyFromSurface`, `.pasteToSurface`; `TabList`, `TabID`; `TabBarView`, `TabBarItem`; `HostWindow`.
- Produces:
  - `final class WindowController` with:
    - `init(contentRect: NSRect, initialCWD: URL?)`
    - `var window: HostWindow { get }`
    - `func showAndStart()`
    - `func handle(_ chord: KeyInterceptor.ReservedChord)` — routes chords to the active tab / tab ops
    - `var focusedCWD: URL?` — the active tab's focused-pane cwd (for `⌘n` inheritance)
    - `var onLastTabClosed: (() -> Void)?` — the window's last tab closed → AppDelegate closes/forgets the window
  - `KeyInterceptor.ReservedChord` gains `.newTab`, `.selectTab(Int)`, `.newWindow`.

- [ ] **Step 1: Add the tab chords to `KeyInterceptor`**

In `Sources/ZenTerm/KeyInterceptor.swift`, extend the `ReservedChord` enum and the switch. Change the enum to:

```swift
    enum ReservedChord {
        case splitVertical, splitHorizontal
        case navLeft, navRight, navUp, navDown
        case closePane
        case newTab, newWindow
        case selectTab(Int)   // 1...9
    }
```

and add cases to the `switch key` before `default`:

```swift
            case "t": chord = .newTab
            case "n": chord = .newWindow
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                chord = key.flatMap { Int($0) }.map { .selectTab($0) }
```

(Leave the existing `\\`, `-`, `h`, `l`, `k`, `j`, `w` cases and the bare-`⌘` `flags == .command` guard unchanged.)

- [ ] **Step 2: Create `Tab`**

Create `Sources/ZenTerm/Tab.swift`:

```swift
import TabKit

/// The chrome's per-tab record beyond the pane controller: its id and last-known
/// title (cached so the tab bar can render without re-querying every controller).
/// The controller itself lives in `WindowController`'s `[TabID: PaneCanvasController]`.
struct Tab {
    let id: TabID
    var title: String
}
```

- [ ] **Step 3: Create `WindowController`**

Create `Sources/ZenTerm/WindowController.swift`. It owns the window, the `TabList`, the controller dict, the title cache, and the tab bar; lays the active `canvasView` above a bottom tab-bar strip; swaps views on select; runs the `⌘w` cascade.

```swift
import AppKit
import TabKit

/// Owns one window and its independent set of tabs. Each tab is a
/// `PaneCanvasController` (Epic 1's pane tree + registry + focus). Only the active
/// tab's `canvasView` is mounted; inactive tabs are detached but retained, so their
/// shells keep running. The tab bar is pinned to the bottom.
final class WindowController: NSObject {
    let window: HostWindow

    private var tabs: TabList
    private var controllers: [TabID: PaneCanvasController] = [:]
    private var titles: [TabID: String] = [:]
    private var nextTabID = 1

    private let container = NSView()
    private let tabBar: TabBarView
    private var mountedCanvas: NSView?

    /// The window's last tab closed → the window should go away.
    var onLastTabClosed: (() -> Void)?

    /// The active tab's focused-pane cwd, for `⌘n` new-window inheritance.
    var focusedCWD: URL? { controllers[tabs.activeID]?.focusedCWD }

    init(contentRect: NSRect, initialCWD: URL?) {
        window = HostWindow(contentRect: contentRect)
        let firstID = TabID(1)
        tabs = TabList(first: firstID)
        // tabBar needs `self` for callbacks; build with placeholders, wire after super.init.
        var onSelect: (TabID) -> Void = { _ in }
        var onClose: (TabID) -> Void = { _ in }
        var onNewTab: () -> Void = { }
        tabBar = TabBarView(onSelect: { onSelect($0) },
                            onClose: { onClose($0) },
                            onNewTab: { onNewTab() })
        super.init()
        nextTabID = 2

        onSelect = { [weak self] in self?.select($0) }
        onClose = { [weak self] in self?.closeTab($0) }
        onNewTab = { [weak self] in self?.newTab() }

        let first = makeController(initialCWD: initialCWD)
        controllers[firstID] = first
        titles[firstID] = first.title

        layoutContainer()
    }

    // MARK: layout

    private func layoutContainer() {
        let content = window.contentView!
        container.frame = content.bounds
        container.autoresizingMask = [.width, .height]
        content.addSubview(container)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ])
    }

    func showAndStart() {
        mountActive()
        controllers[tabs.activeID]?.start()
        window.makeKeyAndOrderFront(nil)
        renderTabBar()
    }

    // MARK: controller factory

    private func makeController(initialCWD: URL?) -> PaneCanvasController {
        let c = PaneCanvasController(initialCWD: initialCWD)
        // Bind title + last-pane-exit to this controller's id at call sites that
        // know the id (newTab / init assign into the dict first, then wire).
        return c
    }

    private func mintTabID() -> TabID { defer { nextTabID += 1 }; return TabID(nextTabID) }

    // MARK: mounting

    /// Mount the active tab's canvas above the tab bar; detach the previous one.
    /// Always restores focus to the active tab's focused pane after mounting.
    private func mountActive() {
        guard let c = controllers[tabs.activeID] else { return }
        if mountedCanvas !== c.canvasView {
            mountedCanvas?.removeFromSuperview()
            let canvas = c.canvasView
            canvas.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(canvas, positioned: .below, relativeTo: tabBar)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                canvas.topAnchor.constraint(equalTo: container.topAnchor),
                canvas.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            ])
            mountedCanvas = canvas
        }
        c.focusActivePane()
    }

    // MARK: tab ops

    private func newTab() {
        let inheritCWD = controllers[tabs.activeID]?.focusedCWD
        let id = mintTabID()
        let c = makeController(initialCWD: inheritCWD)
        controllers[id] = c
        titles[id] = c.title
        wire(c, id: id)
        tabs.add(id)
        mountActive()
        c.start()
        renderTabBar()
    }

    private func select(_ id: TabID) {
        guard id != tabs.activeID else { return }
        tabs.select(id)
        mountActive()
        renderTabBar()
    }

    /// Close a specific tab; cascades to closing the window when it was the last.
    private func closeTab(_ id: TabID) {
        let survived = tabs.close(id)
        if mountedCanvas === controllers[id]?.canvasView { mountedCanvas = nil }
        controllers[id] = nil
        titles[id] = nil
        if !survived { onLastTabClosed?(); return }
        mountActive()
        renderTabBar()
    }

    // MARK: chord routing

    func handle(_ chord: KeyInterceptor.ReservedChord) {
        let active = controllers[tabs.activeID]
        switch chord {
        case .splitVertical:   active?.split(.vertical)
        case .splitHorizontal: active?.split(.horizontal)
        case .navLeft:  active?.navigate(.left)
        case .navRight: active?.navigate(.right)
        case .navUp:    active?.navigate(.up)
        case .navDown:  active?.navigate(.down)
        case .newTab:   newTab()
        case .selectTab(let n):
            let idx = n - 1
            if idx >= 0 && idx < tabs.order.count { select(tabs.order[idx]) }
        case .closePane:
            // pane → tab → window cascade
            if active?.closeFocused() == false { closeTab(tabs.activeID) }
        case .newWindow:
            break   // handled by AppDelegate (window manager); no-op here
        }
    }

    // MARK: wiring

    /// Bind a controller's title + last-pane-exit callbacks to its tab id.
    private func wire(_ c: PaneCanvasController, id: TabID) {
        c.onTitleChanged = { [weak self] in
            guard let self else { return }
            self.titles[id] = c.title
            self.renderTabBar()
        }
        c.onLastPaneClosed = { [weak self] in self?.closeTab(id) }
    }

    private func renderTabBar() {
        let items = tabs.order.enumerated().map { i, id in
            TabBarItem(id: id, index: i + 1,
                       title: titles[id] ?? "~",
                       isActive: id == tabs.activeID)
        }
        tabBar.render(items)
    }

    // Wire the first controller once the dict is populated (called from init tail via showAndStart path).
    func bindFirstControllerIfNeeded() {
        let firstID = tabs.order[0]
        if let c = controllers[firstID] { wire(c, id: firstID) }
    }
}
```

> Note for the implementer — one loose end to close in this step, don't leave it: the first controller (created in `init`) is added to the dict but not yet wired. Call `bindFirstControllerIfNeeded()` at the top of `showAndStart()` (before `mountActive()`), so the initial tab gets its title + last-pane-exit callbacks. The requirement: **every controller (including the first) is wired exactly once via `wire(_:id:)`.** `mountActive()` already calls `focusActivePane()` (added in Step 4) so re-mounting restores focus — no action needed there.

- [ ] **Step 4: Add `focusActivePane()` to `PaneCanvasController`**

In `Sources/ZenTerm/PaneCanvasController.swift`, add a public-to-module method (the existing `focusFrontmost()` is private):

```swift
    /// Restore focus + halo to this tab's focused pane (used when its tab is
    /// re-mounted after a switch).
    func focusActivePane() { focus(tree.focusedLeaf) }
```

- [ ] **Step 5: Simplify `AppDelegate` to drive one `WindowController`**

Replace `Sources/ZenTerm/AppDelegate.swift` so it owns a single `WindowController` (multi-window arrives in PR 3). New content:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: WindowController!
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                  initialCWD: nil)
        wc.window.center()
        wc.onLastTabClosed = { [weak wc] in wc?.window.close() }
        controller = wc

        MainMenu.install(copyPaste: controller)
        wc.showAndStart()
        NSApp.activate(ignoringOtherApps: true)

        keys.onReservedChord = { [weak self] chord in self?.controller.handle(chord) }
        keys.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

> `MainMenu.install(copyPaste:)` expects the object exposing `copyFromSurface:` / `pasteToSurface:`. Those live on `PaneCanvasController`, not `WindowController`. In this task, add thin forwarders on `WindowController` so Copy/Paste route to the active tab's controller:
> ```swift
>     @objc func copyFromSurface(_ sender: Any?) { controllers[tabs.activeID]?.copyFromSurface(sender) }
>     @objc func pasteToSurface(_ sender: Any?) { controllers[tabs.activeID]?.pasteToSurface(sender) }
> ```
> Add these to `WindowController` (they make Copy/Paste follow the active tab).

- [ ] **Step 6: Build and run the manual runbook**

Run: `swift build` (expected clean), then `swift run ZenTerm`.

Manual runbook (this task has no unit test — verify each):
1. App opens with one tab in the bottom-left bar reading `1 <cwd>`.
2. `⌘t` → a second tab appears (`2 <cwd>`), becomes active (iris underline), new shell prompt. `cd` somewhere in tab 1 first, then `⌘t` → tab 2 starts in that cwd (inheritance).
3. In tab 1 run `ping localhost`; `⌘2`/`⌘1` (or click) to switch. Return to tab 1 → ping output **accumulated** while detached (background shell alive).
4. `⌘\` / `⌘-` split inside a tab; switch tabs and back → the split layout and focus are preserved per tab.
5. `⌘w` closes the focused pane; on the tab's last pane it closes the tab; on the window's last tab it closes the window (app quits — single window in PR 2).
6. Title updates: `cd ~/Dev` in the active pane → that tab's title updates live.

- [ ] **Step 7: Commit**

```bash
git add Sources/ZenTerm/Tab.swift Sources/ZenTerm/WindowController.swift Sources/ZenTerm/KeyInterceptor.swift Sources/ZenTerm/AppDelegate.swift Sources/ZenTerm/PaneCanvasController.swift
git commit -m "feat(chrome): in-window tabs — WindowController, view-swap, tab keybinds, close cascade"
```

---

## PR 3 — Multi-window + disable native tabbing

Ship PR 2 first (merge). Branch PR 3 from the ticket's Linear `gitBranchName`.

### Task 5: `AppDelegate` window manager + `⌘n` + disable native tabbing

**Files:**
- Modify: `Sources/ZenTerm/HostWindow.swift` (`tabbingMode = .disallowed`)
- Modify: `Sources/ZenTerm/AppDelegate.swift` (own `[WindowController]`, route to key window, handle `⌘n`)

**Interfaces:**
- Consumes: `WindowController(contentRect:initialCWD:)`, `.window`, `.showAndStart()`, `.handle(_:)`, `.focusedCWD`, `.onLastTabClosed`; `KeyInterceptor.ReservedChord.newWindow`.
- Produces: no new public API — `AppDelegate` internals only.

- [ ] **Step 1: Disable native tabbing on the window**

In `Sources/ZenTerm/HostWindow.swift`, inside `init`, after `isMovableByWindowBackground = true`, add:

```swift
        tabbingMode = .disallowed   // no native macOS tabs / window merging (multi-window + yabai)
```

- [ ] **Step 2: Make `AppDelegate` a window manager**

Replace `Sources/ZenTerm/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WindowController] = []
    private let keys = KeyInterceptor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(copyPaste: nil)    // Copy/Paste route via first responder chain
        newWindow(initialCWD: nil, centered: true)

        keys.onReservedChord = { [weak self] chord in self?.route(chord) }
        keys.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Route a chord: `⌘n` makes a new window; everything else goes to the key
    /// window's controller.
    private func route(_ chord: KeyInterceptor.ReservedChord) {
        if case .newWindow = chord {
            newWindow(initialCWD: keyController()?.focusedCWD, centered: false)
            return
        }
        keyController()?.handle(chord)
    }

    private func keyController() -> WindowController? {
        guard let key = NSApp.keyWindow else { return windows.first }
        return windows.first { $0.window === key }
    }

    private func newWindow(initialCWD: URL?, centered: Bool) {
        let offset = CGFloat(windows.count) * 28
        let rect = NSRect(x: 0, y: 0, width: 900, height: 560).offsetBy(dx: offset, dy: -offset)
        let wc = WindowController(contentRect: rect, initialCWD: initialCWD)
        if centered { wc.window.center() }
        wc.onLastTabClosed = { [weak self, weak wc] in
            guard let self, let wc else { return }
            wc.window.close()
            self.windows.removeAll { $0 === wc }
        }
        windows.append(wc)
        wc.showAndStart()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

> Copy/Paste: `MainMenu` currently sets `copy.target`/`paste.target` to the passed object. With `nil`, AppKit sends `copyFromSurface:` / `pasteToSurface:` down the responder chain. For this to reach the active tab, the `WindowController` (or its content view / the controller) must be in the responder chain. Simplest reliable route for this task: keep `MainMenu.install(copyPaste:)` taking a target, and update the key window's Copy/Paste target on window activation. Implement whichever is cleaner, but the **requirement** is: Copy (`⌘C`) and Paste (`⌘V`) operate on the focused pane of the **key window's active tab**, verified in the runbook. If responder-chain routing is not wired up in one step, pass the first window's controller as the target and update it in a `windowDidBecomeKey` observer.

- [ ] **Step 3: Build and run the manual runbook**

Run: `swift build` (expected clean), then `swift run ZenTerm`.

Manual runbook:
1. `⌘n` opens a second, independent window (offset from the first), made key, with its own single tab.
2. Each window's `⌘t` / `⌘1–9` affects only that window's tabs (independent tab sets).
3. Focus window A, `⌘\` split; focus window B — B is unaffected. Chords act on the key window only.
4. `cd ~/Dev` in window A's focused pane, `⌘n` → new window starts in `~/Dev` (inheritance).
5. Close all tabs in one window (`⌘w` cascade) → only that window closes; the other stays. Close the last window → app quits.
6. Native tabbing is gone: View menu has no "Show Tab Bar"; dragging one window over another does not offer to merge into tabs.
7. Copy in window A (select + `⌘C`), Paste (`⌘V`) into the active tab's focused pane — routes to the key window's active tab.
8. (If available) under yabai, both windows tile as ordinary managed windows.

- [ ] **Step 4: Commit**

```bash
git add Sources/ZenTerm/HostWindow.swift Sources/ZenTerm/AppDelegate.swift Sources/ZenTerm/MainMenu.swift
git commit -m "feat(chrome): multi-window manager, ⌘n, disable native tabbing"
```

---

## Self-review

- **Spec coverage:** in-window numbered tab bar (Task 3), view-swap detach/reattach with background shells alive (Task 4 mount logic + runbook §3), `tabbingMode=.disallowed` (Task 5 §1), `⌘t`/`⌘1–9`/`⌘n` (Tasks 1/4/5), `⌘w` cascade (Task 4 `closeTab`/`handle`), independent multi-window tab sets (Task 5), cwd inheritance for tab + window (Tasks 4/5), titles from cwd basename (Task 2). All spec DoD items map to a task.
- **Type consistency:** `TabID`/`TabList` signatures match between Task 1 (definition) and Tasks 4/5 (consumption): `add`, `select(_:)`, `select(index:)`, `close(_:) -> Bool`, `order`, `activeID`. `PaneCanvasController` additions (`initialCWD`, `title`, `focusedCWD`, `onTitleChanged`, `focusActivePane`) defined in Tasks 2/4 and consumed in Task 4.
- **Loose ends flagged, not deferred:** Task 4's mount-focus and first-controller-wiring, and Task 5's Copy/Paste routing, are called out with explicit requirements to close within the task (no `TODO` left in code).
```
