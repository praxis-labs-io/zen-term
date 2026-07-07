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
        bindFirstControllerIfNeeded()
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

    // MARK: copy/paste — routed to the active tab's controller

    @objc func copyFromSurface(_ sender: Any?) { controllers[tabs.activeID]?.copyFromSurface(sender) }
    @objc func pasteToSurface(_ sender: Any?) { controllers[tabs.activeID]?.pasteToSurface(sender) }

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

    /// Wire the first controller once the dict is populated. Called from
    /// `showAndStart()` before the first `mountActive()` so the initial tab gets
    /// its title + last-pane-exit callbacks exactly once.
    private func bindFirstControllerIfNeeded() {
        let firstID = tabs.order[0]
        if let c = controllers[firstID] { wire(c, id: firstID) }
    }
}
