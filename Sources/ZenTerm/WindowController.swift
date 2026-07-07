import AppKit
import TabKit

/// Owns one window and its independent set of tabs. Each tab is a
/// `TabController` (wrapping Epic 1's pane tree + registry + focus). Only the active
/// tab's `view` is mounted; inactive tabs are detached but retained, so their
/// shells keep running. The tab bar is pinned to the bottom.
final class WindowController: NSObject {
    let window: HostWindow

    private var tabs: TabList
    private var controllers: [TabID: TabController] = [:]
    private var titles: [TabID: String] = [:]
    private var nextTabID = 1

    private let container = NSView()
    private let tabBar: TabBarView
    private var mountedCanvas: NSView?

    /// Re-derives tab titles from each tab's live cwd. Shells report cwd changes
    /// without OSC 7, so there's no push event on `cd` — a light poll keeps titles
    /// current; it only re-renders when a title actually changed.
    private var titlePoll: Timer?

    /// The window has closed (via the last-tab cascade OR the native close button) →
    /// the manager should forget this controller. Fired once, from `windowWillClose`.
    var onClosed: (() -> Void)?

    private var didTearDown = false

    /// The active tab's focused-pane cwd, for `⌘n` new-window inheritance.
    var focusedCWD: URL? { activeController?.focusedCWD }

    /// The active tab's controller, or nil once the last tab has closed (the window
    /// is being torn down). Reading `tabs.activeID` on an empty list traps, so every
    /// active-tab access goes through here.
    private var activeController: TabController? {
        guard !tabs.order.isEmpty else { return nil }
        return controllers[tabs.activeID]
    }

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
        window.delegate = self   // for windowWillClose teardown (native close button + cascade)
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
        bindFirstControllerIfNeeded()
        mountActive()
        activeController?.start()
        window.makeKeyAndOrderFront(nil)
        renderTabBar()
        titlePoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshTitlesFromCWD()
        }
    }

    /// Recompute every tab's title from its live cwd; re-render only on change so a
    /// hovered chip isn't rebuilt out from under the pointer each tick.
    private func refreshTitlesFromCWD() {
        var changed = false
        for id in tabs.order {
            guard let c = controllers[id] else { continue }
            let t = c.title
            if titles[id] != t { titles[id] = t; changed = true }
        }
        if changed { renderTabBar() }
    }

    deinit { titlePoll?.invalidate() }   // backstop; tearDown() normally handles it

    // MARK: controller factory

    private func makeController(initialCWD: URL?) -> TabController {
        let c = TabController(initialCWD: initialCWD)
        // Bind title + last-pane-exit to this controller's id at call sites that
        // know the id (newTab / init assign into the dict first, then wire).
        return c
    }

    private func mintTabID() -> TabID { defer { nextTabID += 1 }; return TabID(nextTabID) }

    // MARK: mounting

    /// Mount the active tab's canvas above the tab bar; detach the previous one.
    /// Always restores focus to the active tab's focused pane after mounting.
    private func mountActive() {
        guard let c = activeController else { return }
        if mountedCanvas !== c.view {
            mountedCanvas?.removeFromSuperview()
            let canvas = c.view
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
        let inheritCWD = activeController?.focusedCWD
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
        guard tabs.order.contains(id), id != tabs.activeID else { return }
        tabs.select(id)
        mountActive()
        renderTabBar()
    }

    /// Close a specific tab: terminate its shells, detach its canvas, and cascade to
    /// closing the window when it was the last tab.
    private func closeTab(_ id: TabID) {
        let survived = tabs.close(id)
        let controller = controllers[id]
        if mountedCanvas === controller?.view {
            controller?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        controller?.shutdown()      // terminate the tab's shells — never leak them
        controllers[id] = nil
        titles[id] = nil
        if !survived { window.close(); return }   // last tab → close window → windowWillClose tears down
        mountActive()
        renderTabBar()
    }

    // MARK: chord routing

    func handle(_ chord: KeyInterceptor.ReservedChord) {
        guard !tabs.order.isEmpty else { return }   // window tearing down after last tab closed
        let active = activeController
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
        case .toggleBottomDrawer: active?.toggleBottomDrawer()
        }
    }

    // MARK: copy/paste — routed to the active tab's controller

    @objc func copyFromSurface(_ sender: Any?) { activeController?.copyFromSurface(sender) }
    @objc func pasteToSurface(_ sender: Any?) { activeController?.pasteToSurface(sender) }

    // MARK: wiring

    /// Bind a controller's title + last-pane-exit callbacks to its tab id.
    private func wire(_ c: TabController, id: TabID) {
        // Look the controller up by id rather than capturing `c` — capturing `c`
        // strongly in a closure stored on `c` would retain the controller forever.
        c.onTitleChanged = { [weak self] in
            guard let self, let c = self.controllers[id] else { return }
            self.titles[id] = c.title
            self.renderTabBar()
        }
        c.onLastPaneClosed = { [weak self] in self?.closeTab(id) }
    }

    private func renderTabBar() {
        let items = tabs.order.enumerated().map { i, id in
            TabBarItem(id: id, index: i + 1,
                       title: titles[id] ?? "shell",
                       isActive: id == tabs.activeID)
        }
        tabBar.render(items)
    }

    /// Wire the first controller once the dict is populated. Called from
    /// `showAndStart()` before the first `mountActive()` so the initial tab gets
    /// its title + last-pane-exit callbacks exactly once.
    private func bindFirstControllerIfNeeded() {
        let firstID = tabs.order[0]
        if let c = controllers[firstID] { wire(c, id: firstID) }
    }

    /// Single teardown path for BOTH the ⌘w last-tab cascade and the native close
    /// button: stop the poll, terminate every still-open tab's shells, and let the
    /// manager forget this window. Idempotent.
    private func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        titlePoll?.invalidate()
        titlePoll = nil
        for c in controllers.values { c.shutdown() }
        controllers.removeAll()
        onClosed?()
    }
}

extension WindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { tearDown() }
}
