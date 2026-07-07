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

    /// Opacity of the base-color tint laid over the behind-window blur. 1 = solid shell,
    /// 0 = raw system blur. Tuned for a cohesive shell that still shows depth through the
    /// gutters; the single knob for the whole transparent look.
    private static let backdropTintAlpha: CGFloat = 0.82

    private let container = NSView()
    private let tabBar: TabBarView
    private let dock: ToggleDock
    private var mountedCanvas: NSView?

    /// The `⌘P` repo picker, when open. Window-level (it opens/replaces tabs) but
    /// presented over the active tab's tile region. Modal while open.
    private var repoPicker: RepoPickerOverlay?
    var isRepoPickerOpen: Bool { repoPicker != nil }

    /// The `⌘P` command palette, when open. Window-level like the repo picker (it can
    /// open/switch tabs) but presented over the active tab's tile region. Modal while open.
    private var commandPalette: CommandPaletteOverlay?
    var isCommandPaletteOpen: Bool { commandPalette != nil }

    /// Whether either palette is modal right now. Read by `AppDelegate` so window-level
    /// chords (⌘N) and Copy/Paste routing respect the modal too, not just `handle(_:)`.
    var isModalPaletteOpen: Bool { isRepoPickerOpen || isCommandPaletteOpen }

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
        // Both tabBar and dock need `self` for callbacks; build with placeholders, wire
        // after super.init (so both can stay `let`).
        var onSelect: (TabID) -> Void = { _ in }
        var onClose: (TabID) -> Void = { _ in }
        var onNewTab: () -> Void = {}
        tabBar = TabBarView(
            onSelect: { onSelect($0) },
            onClose: { onClose($0) },
            onNewTab: { onNewTab() })
        var onSplitH: () -> Void = {}
        var onSplitV: () -> Void = {}
        var onPalette: () -> Void = {}
        var onBottom: () -> Void = {}
        var onRight: () -> Void = {}
        var onZoom: () -> Void = {}
        var onLazygit: () -> Void = {}
        dock = ToggleDock(
            onSplitH: { onSplitH() }, onSplitV: { onSplitV() },
            onPalette: { onPalette() }, onBottom: { onBottom() },
            onRight: { onRight() }, onZoom: { onZoom() }, onLazygit: { onLazygit() })
        super.init()
        nextTabID = 2

        onSelect = { [weak self] in self?.select($0) }
        onClose = { [weak self] in self?.closeTab($0) }
        onNewTab = { [weak self] in self?.newTab() }
        // Dock buttons route through `handle(_:)` (not the tab directly) so they obey the
        // same modal gates as the keyboard chords.
        onSplitH = { [weak self] in self?.handle(.splitHorizontal) }
        onSplitV = { [weak self] in self?.handle(.splitVertical) }
        onPalette = { [weak self] in self?.handle(.toggleCommandPalette) }
        onBottom = { [weak self] in self?.handle(.toggleBottomDrawer) }
        onRight = { [weak self] in self?.handle(.toggleRightDrawer) }
        onZoom = { [weak self] in self?.handle(.toggleZoom) }
        onLazygit = { [weak self] in self?.handle(.toggleLazygit) }

        let first = makeController(initialCWD: initialCWD)
        controllers[firstID] = first
        titles[firstID] = first.title

        layoutContainer()
        window.delegate = self  // for windowWillClose teardown (native close button + cascade)
    }

    // MARK: layout

    private func layoutContainer() {
        let content = window.contentView!

        // Backmost: a behind-window blur, then a base-color tint over it. Everything the
        // opaque terminal surfaces don't cover (pane gutters, window inset, rounded pane
        // corners) reads as this tinted, blurred backdrop. The tint keeps the chrome on-brand
        // instead of a raw system blur; its alpha is the one knob to dial the look.
        let backdrop = NSVisualEffectView(frame: content.bounds)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        content.addSubview(backdrop)

        let tint = NSView(frame: content.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor =
            Theme.rosePineMoon.background.nsColor.withAlphaComponent(Self.backdropTintAlpha).cgColor
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)

        container.frame = content.bounds
        container.autoresizingMask = [.width, .height]
        content.addSubview(container)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        dock.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBar)
        container.addSubview(dock)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            // Dock sits at the trailing edge of the tab-bar row; the tab strip ends before
            // it (== so the tab bar's width is unambiguous). The dock shares the chips' -6
            // band nudge so its icons align with the tab labels, not 6pt below them.
            dock.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            dock.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor, constant: -6),
            tabBar.trailingAnchor.constraint(equalTo: dock.leadingAnchor, constant: -8),
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

    deinit { titlePoll?.invalidate() }  // backstop; tearDown() normally handles it

    // MARK: controller factory

    private func makeController(initialCWD: URL?, workspace: Bool = false) -> TabController {
        // The ⌘P workspace preset seeds the primary pane with nvim and the right drawer
        // with claude; the caller calls `openWorkspaceLayout()` after `start()` to reveal
        // the drawers. A plain tab (⌘t / first tab) gets neither.
        // `nvim` (no path arg): opens the normal dashboard in the repo cwd, exactly like
        // typing `nvim` at a prompt. `nvim .` would open the directory and expand the file
        // explorer, which isn't what a bare launch does.
        let c = TabController(initialCWD: initialCWD, initialCommand: workspace ? "nvim" : nil)
        if workspace { c.rightDrawerCommand = "claude" }
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
        c.restoreKeyFocus()  // float-aware: keeps focus on the modal float when open
        renderDock()  // dock mirrors the newly-active tab's overlay state
    }

    // MARK: tab ops

    private func newTab() { addTab(cwd: activeController?.focusedCWD, pinnedTitle: nil) }

    /// Append a new tab with an explicit cwd and optional pinned title (the `⌘P` repo
    /// picker passes the repo dir + its basename; plain `⌘t` passes the inherited cwd
    /// and no pin).
    private func addTab(cwd: URL?, pinnedTitle: String?, workspace: Bool = false) {
        dismissOpenPalettes()  // the "+" button is reachable while a palette is up
        let id = mintTabID()
        tabs.add(id)
        installController(id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace)
    }

    /// Replace the active tab's controller in place (same tab id/slot) with a fresh
    /// workspace session in `cwd`, pinned to `pinnedTitle`. Used by `⌘P` + Shift+Enter.
    private func replaceActiveTab(cwd: URL, pinnedTitle: String?) {
        let id = tabs.activeID
        let old = controllers[id]
        if mountedCanvas === old?.view {
            old?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        old?.shutdown()  // terminate the replaced tab's shells — never leak them
        installController(id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: true)
    }

    /// Build, wire, mount, and start a controller for `id` (already in `tabs`), applying
    /// the workspace preset when requested. Shared by new-tab and replace-tab.
    private func installController(id: TabID, cwd: URL?, pinnedTitle: String?, workspace: Bool) {
        let c = makeController(initialCWD: cwd, workspace: workspace)
        c.pinnedTitle = pinnedTitle
        controllers[id] = c
        titles[id] = c.title
        wire(c, id: id)
        mountActive()
        c.start()
        if workspace { c.openWorkspaceLayout() }
        renderTabBar()
    }

    private func select(_ id: TabID) {
        dismissOpenPalettes()  // a tab-bar click must not orphan a modal palette
        guard tabs.order.contains(id), id != tabs.activeID else { return }
        tabs.select(id)
        mountActive()
        renderTabBar()
    }

    /// Cycle the active tab by `delta` (⌘] = +1, ⌘[ = -1), wrapping around the ends.
    /// No-op with a single tab.
    private func cycleTab(_ delta: Int) {
        guard tabs.order.count > 1, let i = tabs.order.firstIndex(of: tabs.activeID) else { return }
        let n = tabs.order.count
        select(tabs.order[(i + delta + n) % n])
    }

    /// Close a specific tab: terminate its shells, detach its canvas, and cascade to
    /// closing the window when it was the last tab.
    private func closeTab(_ id: TabID) {
        dismissOpenPalettes()  // the "×" button is reachable while a palette is up
        let survived = tabs.close(id)
        let controller = controllers[id]
        if mountedCanvas === controller?.view {
            controller?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        controller?.shutdown()  // terminate the tab's shells — never leak them
        controllers[id] = nil
        titles[id] = nil
        if !survived { window.close(); return }  // last tab → close window → windowWillClose tears down
        mountActive()
        renderTabBar()
    }

    // MARK: repo picker (⌘⇧P)

    /// Toggle the repo picker over the active tab. Scans `~/dev` fresh on open and
    /// focuses its search field. Closing (⌘⇧P again, Esc, backdrop, or after a choice)
    /// restores keyboard focus to the active tab.
    private func toggleRepoPicker() {
        if isRepoPickerOpen { closeRepoPicker(); return }
        guard let active = activeController else { return }
        let picker = RepoPickerOverlay(
            entries: RepoScanner.scan(root: RepoScanner.defaultRoot),
            background: Theme.rosePineMoon.background.nsColor,
            onChoose: { [weak self] dir, replace in self?.openRepo(dir, replaceCurrentTab: replace) },
            onDismiss: { [weak self] in self?.closeRepoPicker() }
        )
        active.presentTileOverlay(picker)
        repoPicker = picker
        picker.focusSearchField()
        renderDock()  // palette button now active
    }

    private func closeRepoPicker() {
        repoPicker?.removeFromSuperview()
        repoPicker = nil
        activeController?.restoreKeyFocus()
        renderDock()  // palette button now inactive
    }

    // MARK: command palette (⌘P)

    /// Toggle the command palette over the active tab. Builds the catalog fresh (its
    /// tab-select entries track the live tab count) and focuses its search field. Closing
    /// (⌘P again, Esc, backdrop, or after running a command) restores focus to the tab.
    private func toggleCommandPalette() {
        if isCommandPaletteOpen { closeCommandPalette(); return }
        guard let active = activeController else { return }
        let palette = CommandPaletteOverlay(
            commands: CommandCatalog.commands(tabCount: tabs.order.count),
            background: Theme.rosePineMoon.background.nsColor,
            onRun: { [weak self] chord in self?.runCommand(chord) },
            onDismiss: { [weak self] in self?.closeCommandPalette() }
        )
        active.presentTileOverlay(palette)
        commandPalette = palette
        palette.focusSearchField()
        renderDock()  // command button now active
    }

    private func closeCommandPalette() {
        commandPalette?.removeFromSuperview()
        commandPalette = nil
        activeController?.restoreKeyFocus()
        renderDock()  // command button now inactive
    }

    /// Run a chosen command: close the palette first (clears its modal gate), then dispatch
    /// the chord through the normal `handle(_:)` path — including `.toggleRepoPicker`, which
    /// opens the repo picker once the palette is gone.
    private func runCommand(_ chord: KeyInterceptor.ReservedChord) {
        closeCommandPalette()
        handle(chord)
    }

    // MARK: modal dismissal

    /// Dismiss whichever palette is up — called before any tab-bar mouse op (select/new/
    /// close), which would otherwise unmount the palette's host tab and leave its modal
    /// flag stuck on, soft-locking every keyboard chord.
    private func dismissOpenPalettes() {
        if isRepoPickerOpen { closeRepoPicker() }
        if isCommandPaletteOpen { closeCommandPalette() }
    }

    /// Open a picked directory as a shell session: a new tab (Enter) or by replacing
    /// the current tab (Shift+Enter). Either way the tab name is pinned to the dir
    /// basename so it survives the focused pane's cwd changes.
    private func openRepo(_ dir: URL, replaceCurrentTab: Bool) {
        closeRepoPicker()
        let name = dir.lastPathComponent
        // A repo open builds the workspace layout: nvim in the primary pane, claude in
        // the right drawer, a shell in the bottom drawer.
        if replaceCurrentTab {
            replaceActiveTab(cwd: dir, pinnedTitle: name)
        } else {
            addTab(cwd: dir, pinnedTitle: name, workspace: true)
        }
    }

    // MARK: chord routing

    func handle(_ chord: KeyInterceptor.ReservedChord) {
        guard !tabs.order.isEmpty else { return }  // window tearing down after last tab closed
        let active = activeController
        // The repo picker is modal over the window: while it's open only ⌘P (close it)
        // acts; every other chord is swallowed. Its arrow/Enter/Esc keys aren't chords —
        // they go to the search field's field editor, never here.
        if isRepoPickerOpen {
            if case .toggleRepoPicker = chord { toggleRepoPicker() }
            return
        }
        // The command palette is modal the same way: while it's open only ⌘P (close it)
        // acts; every other chord is swallowed. Running a command closes the palette first,
        // so the dispatched chord arrives here with the gate already clear.
        if isCommandPaletteOpen {
            if case .toggleCommandPalette = chord { toggleCommandPalette() }
            return
        }
        // The lazygit float is modal over its tab: while it's open, every tab-internal
        // chord (split/nav/close/drawers/zoom) is swallowed. Only ⌘G (toggle it off) and
        // cross-tab/window chords — switch tab, new tab, new window — still act. The
        // palettes aren't in the allow-list, so neither can open over the float.
        if active?.isLazygitOpen == true {
            switch chord {
            case .toggleLazygit, .newTab, .newWindow, .selectTab, .prevTab, .nextTab:
                break
            default:
                return
            }
        }
        switch chord {
        case .splitVertical: active?.split(.vertical)
        case .splitHorizontal: active?.split(.horizontal)
        case .navLeft: active?.navigate(.left)
        case .navRight: active?.navigate(.right)
        case .navUp: active?.navigate(.up)
        case .navDown: active?.navigate(.down)
        case .resizeLeft: active?.resize(.left)
        case .resizeRight: active?.resize(.right)
        case .resizeUp: active?.resize(.up)
        case .resizeDown: active?.resize(.down)
        case .newTab: newTab()
        case .selectTab(let n):
            let idx = n - 1
            if idx >= 0 && idx < tabs.order.count { select(tabs.order[idx]) }
        case .prevTab: cycleTab(-1)
        case .nextTab: cycleTab(1)
        case .closePane:
            // pane → tab → window cascade
            if active?.closeFocused() == false { closeTab(tabs.activeID) }
        case .newWindow:
            break  // handled by AppDelegate (window manager); no-op here
        case .toggleBottomDrawer: active?.toggleBottomDrawer()
        case .toggleRightDrawer: active?.toggleRightDrawer()
        case .toggleZoom: active?.toggleZoom()
        case .toggleLazygit: active?.toggleLazygit()
        case .toggleRepoPicker: toggleRepoPicker()
        case .toggleCommandPalette: toggleCommandPalette()
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
        // Only the active tab toggles overlays (chords route to it); re-render the dock
        // so its tints track that tab.
        c.onOverlayStateChanged = { [weak self] in self?.renderDock() }
    }

    private func renderTabBar() {
        let items = tabs.order.enumerated().map { i, id in
            TabBarItem(
                id: id, index: i + 1,
                title: titles[id] ?? "shell",
                isActive: id == tabs.activeID)
        }
        tabBar.render(items)
    }

    /// Mirror the active tab's overlay state + the window's command-palette state onto the
    /// dock's active tints. Called on tab switch, overlay toggles, and palette open/close.
    private func renderDock() {
        dock.render(overlay: activeController?.overlayState ?? OverlayState(), paletteOpen: isCommandPaletteOpen)
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
