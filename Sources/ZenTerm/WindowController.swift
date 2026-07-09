import AppKit
import TabKit
import TerminalKit

/// Owns one window and its independent set of tabs. Each tab is a
/// `TabController` (wrapping Epic 1's pane tree + registry + focus). Only the active
/// tab's `view` is mounted; inactive tabs are detached but retained, so their
/// shells keep running. The tab bar is pinned to the bottom.
final class WindowController: NSObject {
    let window: HostWindow

    private var tabs: TabList
    private var controllers: [TabID: TabController] = [:]
    private var titles: [TabID: String] = [:]
    /// Tabs wanting attention while in the background (a terminal bell or an OSC 777 agent
    /// notification) — their number shows rose ("waiting"). Latched from a non-active tab;
    /// cleared when the tab is shown. Each also owns a persistent toast in `waitingToasts`,
    /// dismissed together in `clearWaiting`.
    private var waitingTabs: Set<TabID> = []
    private var waitingToasts: [TabID: ToastView] = [:]
    private var nextTabID = 1

    /// Opacity of the base-color tint laid over the behind-window blur. 1 = solid shell,
    /// 0 = raw system blur. Tuned for a cohesive shell that still shows depth through the
    /// gutters; the single knob for the whole transparent look.
    private static let backdropTintAlpha: CGFloat = 0.82

    private let container = NSView()
    /// Top-right transient notices (e.g. "not a git repository"). Lazy so its stack mounts
    /// above the canvas on first use; window-level so it's shared by every tab.
    private lazy var toasts = ToastPresenter(
        host: container, topInset: ChromeMetrics.windowGutter + 12, trailingInset: ChromeMetrics.windowGutter + 12)
    private let tabBar: TabBarView
    private let dock: ToggleDock
    private var mountedCanvas: NSView?

    /// The `⌘⇧P` repo picker, when open. Window-level (it opens/replaces tabs) but
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

    /// A blocking close confirm (⌘W on a busy or last pane), when up. Window-level like
    /// the palettes: modal over the active tab until answered.
    private var confirmToast: ToastView?
    private var confirmOnCancel: (() -> Void)?
    var isConfirmOpen: Bool { confirmToast != nil }

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
        var onToolFloat: (ToolFloat) -> Void = { _ in }
        dock = ToggleDock(
            onSplitH: { onSplitH() }, onSplitV: { onSplitV() },
            onPalette: { onPalette() }, onBottom: { onBottom() },
            onRight: { onRight() }, onZoom: { onZoom() }, onLazygit: { onLazygit() },
            toolFloats: ToolFloatCatalog.all, onToolFloat: { onToolFloat($0) })
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
        onToolFloat = { [weak self] spec in self?.handle(.toggleToolFloat(spec.id)) }

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
        mount(.instant)
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
        // The ⌘⇧P workspace preset seeds the primary pane with nvim and the right drawer
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

    /// The incoming tab's canvas slides in from this edge on a switch.
    enum SlideEdge { case fromRight, fromLeft }

    /// How the active tab's canvas replaces the previous one.
    enum MountTransition {
        case instant  // new tab's first mount, tab close
        case slide(from: SlideEdge)  // switching between existing tabs
        case fade  // a brand-new tab (no travel direction)
    }

    /// Mount the active tab's canvas above the tab bar, replacing the previous one with the
    /// given transition, and restore focus to the active tab. Animated transitions defer the
    /// previous canvas's removal to their completion, guarded so a rapid re-switch that
    /// re-mounts it doesn't delete the now-active terminal.
    private func mount(_ transition: MountTransition) {
        guard let c = activeController, mountedCanvas !== c.view else {
            activeController?.restoreKeyFocus()  // same canvas: just refresh focus/dock
            renderDock()
            return
        }
        let outgoing = mountedCanvas
        pinCanvas(c.view)
        mountedCanvas = c.view
        c.restoreKeyFocus()  // float-aware: keeps focus on the modal float when open
        renderDock()  // dock mirrors the newly-active tab's overlay state

        switch transition {
        case .instant:
            outgoing?.removeFromSuperview()
        case .slide(let edge):
            container.layoutSubtreeIfNeeded()  // resolve the canvas width before offsetting it
            let dx = edge == .fromRight ? container.bounds.width : -container.bounds.width
            Motion.slideSwap(incoming: c.view, outgoing: outgoing, dx: dx) { [weak self] in
                self?.detachIfInactive(outgoing)
            }
        case .fade:
            guard outgoing != nil else { break }  // first mount: appear instantly
            c.view.layer?.opacity = 0
            Motion.fade(c.view, to: 1) { [weak self] in self?.detachIfInactive(outgoing) }
        }
    }

    /// Remove a canvas left over from a transition — unless a rapid re-switch has since
    /// re-mounted it as the active canvas.
    private func detachIfInactive(_ canvas: NSView?) {
        guard let canvas, canvas !== mountedCanvas else { return }
        canvas.removeFromSuperview()
    }

    private func pinCanvas(_ canvas: NSView) {
        // Re-mounting a canvas mid-transition (rapid switch): cancel its in-flight
        // slide/fade and reset transform/opacity so it starts clean, and reuse its existing
        // constraints rather than stacking a second set.
        canvas.wantsLayer = true
        canvas.layer?.removeAllAnimations()
        canvas.layer?.transform = CATransform3DIdentity
        canvas.layer?.opacity = 1
        if canvas.superview === container {
            container.addSubview(canvas, positioned: .below, relativeTo: tabBar)  // just restack
            return
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas, positioned: .below, relativeTo: tabBar)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
        ])
    }

    // MARK: tab ops

    private func newTab() {
        cancelConfirm()  // the tab-bar "+" is reachable by mouse while a confirm is up
        addTab(cwd: activeController?.focusedCWD, pinnedTitle: nil)
    }

    /// Append a new tab with an explicit cwd and optional pinned title (the `⌘⇧P` repo
    /// picker passes the repo dir + its basename; plain `⌘t` passes the inherited cwd
    /// and no pin).
    private func addTab(cwd: URL?, pinnedTitle: String?, workspace: Bool = false) {
        dismissOpenPalettes()  // the "+" button is reachable while a palette is up
        let id = mintTabID()
        tabs.add(id)
        installController(id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace)
    }

    /// Replace the active tab's controller in place (same tab id/slot) with a fresh
    /// workspace session in `cwd`, pinned to `pinnedTitle`. Used by `⌘⇧P` + Shift+Enter.
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
        mount(.fade)
        c.start()
        if workspace { c.openWorkspaceLayout() }
        renderTabBar()
    }

    private func select(_ id: TabID, slideFrom: SlideEdge? = nil) {
        dismissOpenPalettes()  // a tab-bar click must not orphan a modal palette
        guard tabs.order.contains(id), id != tabs.activeID else { return }
        clearWaiting(id)  // seeing the tab clears its rose flag + dismisses its bell toast
        cancelConfirm()  // switching tabs voids a pending close confirm (its target moved)
        let oldIndex = tabs.order.firstIndex(of: tabs.activeID) ?? 0
        tabs.select(id)
        let newIndex = tabs.order.firstIndex(of: id) ?? 0
        // A later tab enters from the right; an earlier one from the left. Cycling passes an
        // explicit edge so a wrap-around still slides the way the keystroke implies.
        mount(.slide(from: slideFrom ?? (newIndex > oldIndex ? .fromRight : .fromLeft)))
        renderTabBar()
    }

    /// Cycle the active tab by `delta` (⌘] = +1, ⌘[ = -1), wrapping around the ends.
    /// No-op with a single tab.
    private func cycleTab(_ delta: Int) {
        guard tabs.order.count > 1, let i = tabs.order.firstIndex(of: tabs.activeID) else { return }
        let n = tabs.order.count
        select(tabs.order[(i + delta + n) % n], slideFrom: delta > 0 ? .fromRight : .fromLeft)
    }

    /// Close a specific tab: terminate its shells, detach its canvas, and cascade to
    /// closing the window when it was the last tab.
    private func closeTab(_ id: TabID) {
        dismissOpenPalettes()  // the "×" button is reachable while a palette is up
        cancelConfirm()  // a middle-click close voids a pending confirm on another tab
        let survived = tabs.close(id)
        let controller = controllers[id]
        if mountedCanvas === controller?.view {
            controller?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        controller?.shutdown()  // terminate the tab's shells — never leak them
        controllers[id] = nil
        titles[id] = nil
        clearWaiting(id)
        if !survived { window.close(); return }  // last tab → close window → windowWillClose tears down
        mount(.instant)
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
        picker.animateIn()
        renderDock()  // palette button now active
    }

    private func closeRepoPicker() {
        guard let picker = repoPicker else { return }
        // Clear the ref now so the modal gate lifts immediately (focus/dock update this
        // turn, a second Esc/toggle is a no-op); the card finishes springing out after.
        repoPicker = nil
        picker.animateOut { picker.removeFromSuperview() }
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
        palette.animateIn()
        renderDock()  // command button now active
    }

    private func closeCommandPalette() {
        guard let palette = commandPalette else { return }
        // Clear the ref now so the modal gate lifts immediately (focus/dock update this
        // turn, a second Esc/toggle is a no-op); the card finishes springing out after.
        commandPalette = nil
        palette.animateOut { palette.removeFromSuperview() }
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

    /// Present a blocking confirm: focus leaves the terminal (typing is gated) and
    /// the modal chord-gate swallows other chords until Cancel / confirm answers.
    /// `onCancel` runs after Cancel dismisses the toast — needed by callers (e.g. app
    /// quit) that must resolve a pending request of their own on the cancel path too.
    func presentConfirm(
        variant: ToastVariant, title: String, message: String,
        confirmLabel: String, onConfirm: @escaping () -> Void, onCancel: (() -> Void)? = nil
    ) {
        cancelConfirm()  // supersede any confirm already up (e.g. ⌘Q over a ⌘W confirm)
        dismissOpenPalettes()  // never stack over an open palette
        confirmOnCancel = onCancel
        let content = ToastContent(variant: variant, title: title, message: message)
        let actions = [
            ToastAction(title: "Cancel", kind: .cancel) { [weak self] in self?.cancelConfirm() },
            ToastAction(title: confirmLabel, kind: .destructive) { [weak self] in
                // The button stays key-live during its spring-out; ignore a repeat/held Return.
                guard self?.confirmToast != nil else { return }
                self?.tearDownConfirm()  // resolves via onConfirm, not onCancel
                onConfirm()
            },
        ]
        let toast = toasts.confirm(content, actions: actions)
        confirmToast = toast
        window.makeFirstResponder(toast)  // gate terminal typing; key equivs still fire
        renderDock()
    }

    /// Void a pending confirm as if Cancel was pressed — the Cancel button, and any
    /// context change that moves the confirm's target (a tab switch/close/new, or a
    /// pane-focus change), route here. Runs the caller's `onCancel` so an owner (e.g.
    /// app quit) can resolve its own pending state. No-op when no confirm is open.
    private func cancelConfirm() {
        guard confirmToast != nil else { return }
        let onCancel = confirmOnCancel
        tearDownConfirm()
        onCancel?()
    }

    /// Remove the confirm toast and hand focus back to the pane, WITHOUT running
    /// `onCancel` — the confirm (destructive) path resolves through `onConfirm` instead.
    private func tearDownConfirm() {
        guard let toast = confirmToast else { return }
        confirmToast = nil
        confirmOnCancel = nil
        toasts.dismiss(toast)
        activeController?.restoreKeyFocus()  // hand focus back to the pane
        renderDock()
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
        // The close confirm is modal over the window: while it's up every chord is
        // swallowed. Its Return/Esc/button answers go through the toast's own key
        // equivalents, never here.
        if isConfirmOpen { return }
        // The repo picker is modal over the window: ⌘⇧P closes it, another surface's toggle
        // (command palette, lazygit, a tool float) closes it and opens that instead — a live
        // switch between all the modal cards; every other chord is swallowed. Its arrow/Enter/
        // Esc keys aren't chords — they go to the search field's field editor, never here.
        if isRepoPickerOpen {
            switch chord {
            case .toggleRepoPicker:
                closeRepoPicker()
                return
            case .toggleCommandPalette, .toggleLazygit, .toggleToolFloat:
                closeRepoPicker()  // close the picker, then open the requested surface below
            default:
                return
            }
        }
        // The command palette is modal the same way: ⌘P closes it, another surface's toggle
        // switches to it; every other chord is swallowed.
        if isCommandPaletteOpen {
            switch chord {
            case .toggleCommandPalette:
                closeCommandPalette()
                return
            case .toggleRepoPicker, .toggleLazygit, .toggleToolFloat:
                closeCommandPalette()  // close the palette, then open the requested surface below
            default:
                return
            }
        }
        // The lazygit float is modal over its tab. ⌘G closes it; another surface's toggle
        // (a tool float, either palette) closes it and opens that instead — a live switch.
        // ⌘W is guarded with a brief note (it never reaches the pane behind the float);
        // split/nav/drawer/zoom are swallowed; cross-tab/window chords still act.
        if active?.isLazygitOpen == true {
            switch chord {
            case .closePane:
                toasts.show(
                    ToastContent(
                        variant: .info, title: "Close Pane",
                        message: "Close lazygit first to close a pane."))
                return
            case .toggleToolFloat, .toggleCommandPalette, .toggleRepoPicker:
                active?.toggleLazygit()  // close lazygit, then fall through to open the other
            case .toggleLazygit, .newTab, .newWindow, .selectTab, .prevTab, .nextTab:
                break
            default:
                return
            }
        }
        // Tool floats are modal like lazygit: their own toggle closes them, another surface's
        // toggle switches to it, ⌘W is guarded, cross-tab/window chords still act.
        if active?.isToolFloatOpen == true {
            switch chord {
            case .closePane:
                let name =
                    active?.activeToolFloatID.flatMap(ToolFloatCatalog.byID)
                    .map { $0.title.replacingOccurrences(of: "Open ", with: "") } ?? "the tool"
                toasts.show(
                    ToastContent(
                        variant: .info, title: "Close Pane",
                        message: "Close \(name) first to close a pane."))
                return
            case .toggleLazygit, .toggleCommandPalette, .toggleRepoPicker:
                active?.closeToolFloat()  // close it, then fall through to open the other
            case .toggleToolFloat, .newTab, .newWindow, .selectTab, .prevTab, .nextTab:
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
        case .closePane: requestClosePane()
        case .newWindow:
            break  // handled by AppDelegate (window manager); no-op here
        case .toggleBottomDrawer: active?.toggleBottomDrawer()
        case .toggleRightDrawer: active?.toggleRightDrawer()
        case .toggleZoom: active?.toggleZoom()
        case .toggleLazygit: active?.toggleLazygit()
        case .toggleToolFloat(let id):
            if let spec = ToolFloatCatalog.byID(id) { active?.toggleToolFloat(spec) }
        case .toggleRepoPicker: toggleRepoPicker()
        case .toggleCommandPalette: toggleCommandPalette()
        }
    }

    /// Number of open tabs in this window (for the quit tally).
    var tabCount: Int { tabs.order.count }

    /// Present the app-quit confirm on this (key) window. `onQuit` resolves the pending
    /// `.terminateLater` reply with `true`; Cancel resolves it with `false` via the
    /// `onCancel` hook on `presentConfirm` so the app never leaks a pending request.
    func presentQuitConfirm(
        tabCount: Int, windowCount: Int, onQuit: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        let message: String
        if windowCount > 1 {
            message =
                "Quitting will close \(tabCount) tabs in \(windowCount) windows "
                + "and stop everything running in them."
        } else if tabCount == 1 {
            message = "Quitting will close your tab and stop everything running in it."
        } else {
            message = "Quitting will close all \(tabCount) tabs and stop everything running in them."
        }
        presentConfirm(
            variant: .warning, title: "Quit ZenTerm", message: message,
            confirmLabel: "Quit", onConfirm: onQuit, onCancel: onCancel)
    }

    /// ⌘W: close silently when there's nothing to lose; otherwise confirm first.
    /// - A non-last pane confirms only if it's busy (mid-tab work).
    /// - The last pane closes the tab: if it's the only tab (so ⌘W closes the window), it
    ///   confirms only when a pane or drawer is busy; if other tabs remain, closing this tab
    ///   is itself worth a confirm even when idle. `exit`/middle-click stay out of scope.
    private func requestClosePane() {
        guard let active = activeController else { return }
        let lastPane = active.isSinglePane
        let busy = active.focusedPaneIsBusy

        // Only the last-pane path consults drawers, so probe them lazily (2 syscalls).
        let running = lastPane ? (busy || active.hasBusyDrawer) : busy
        let needsConfirm: Bool
        if lastPane {
            let closesWindow = tabs.order.count == 1
            needsConfirm = closesWindow ? running : true
        } else {
            needsConfirm = busy
        }
        guard needsConfirm else {
            // Nothing to lose → close now, cascading to the tab when it was the last pane.
            if active.closeFocused() == false { closeTab(tabs.activeID) }
            return
        }

        // The action is always "Close Pane" — closing the tab is a side effect stated in the body.
        let title = "Close Pane"
        let message: String
        if !lastPane {
            message = "Closing this pane will stop the process running in it."
        } else if running {
            message = "Closing this pane will also close the tab and stop everything running in it."
        } else {
            message = "Closing this pane will also close the tab."
        }
        presentConfirm(
            variant: .warning, title: title, message: message, confirmLabel: "Close"
        ) { [weak self] in
            guard let self, let active = self.activeController else { return }
            if active.closeFocused() == false { self.closeTab(self.tabs.activeID) }
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
        c.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        // A pane click while a close confirm is up moves the confirm's target — void it.
        c.onFocusChanged = { [weak self] in self?.cancelConfirm() }
        c.onBellRang = { [weak self] in self?.agentBellRang(id: id) }
        c.onNotification = { [weak self] n in self?.agentNotified(id: id, notification: n) }
    }

    /// A background tab rang the terminal bell → flag it as wanting attention (its number
    /// shows rose), unless it's the tab you're already looking at. Repeat bells are ignored.
    /// We only know *which* tab rang, not what in it (any program can emit a bell, and it's
    /// often gone before we could probe), so the copy stays generic.
    private func agentBellRang(id: TabID) {
        // The bell may arrive on SwiftTerm's read path; only touch the UI on main.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabs.order.contains(id), id != self.tabs.activeID else { return }
            guard self.waitingTabs.insert(id).inserted else { return }  // ignore repeat bells
            self.renderTabBar()
            self.presentWaitingToast(for: id, message: "Rang the terminal bell")
        }
    }

    /// A background tab posted an OSC 777 desktop notification (e.g. an agent asking for
    /// permission or waiting for input) → flag it and show the notification's own message.
    /// Unlike a bell, a repeat refreshes the toast in place, so "needs permission" updates to
    /// "waiting for input" without stacking.
    private func agentNotified(id: TabID, notification: TerminalNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabs.order.contains(id), id != self.tabs.activeID else { return }
            if self.waitingTabs.insert(id).inserted { self.renderTabBar() }
            let message = notification.body.isEmpty ? notification.title : notification.body
            self.presentWaitingToast(for: id, message: message)
        }
    }

    /// Show (or replace) the persistent, non-modal attention toast for a background tab. The
    /// title is the tab's name. It answers only through its buttons — "Switch" jumps to the
    /// tab, "Dismiss" clears the notice — and visiting the tab any other way clears it too.
    private func presentWaitingToast(for id: TabID, message: String) {
        if let old = waitingToasts[id] { toasts.dismiss(old) }  // replace any prior toast for this tab
        let content = ToastContent(
            variant: .info, title: titles[id] ?? "shell", message: message, icon: "bell.fill")
        let actions = [
            ToastAction(title: "Switch", kind: .destructive) { [weak self] in self?.select(id) },
            ToastAction(title: "Dismiss", kind: .cancel) { [weak self] in
                guard let self else { return }
                self.clearWaiting(id)
                self.renderTabBar()  // "Dismiss" also drops the rose flag
            },
        ]
        waitingToasts[id] = toasts.showSticky(content, actions: actions)
    }

    /// Clear a tab's waiting state: drop the rose flag and dismiss its toast. Called when the
    /// tab is shown or closed. Re-render is left to the caller (all callers already do).
    private func clearWaiting(_ id: TabID) {
        waitingTabs.remove(id)
        if let toast = waitingToasts.removeValue(forKey: id) { toasts.dismiss(toast) }
    }

    private func renderTabBar() {
        let items = tabs.order.enumerated().map { i, id in
            TabBarItem(
                id: id, index: i + 1,
                title: titles[id] ?? "shell",
                isActive: id == tabs.activeID,
                agentState: waitingTabs.contains(id) ? .waiting : .idle)
        }
        tabBar.render(items)
    }

    /// Mirror the active tab's overlay state + the window's command-palette state onto the
    /// dock's active tints. Called on tab switch, overlay toggles, and palette open/close.
    private func renderDock() {
        dock.render(overlay: activeController?.overlayState ?? OverlayState(), paletteOpen: isCommandPaletteOpen)
    }

    /// Wire the first controller once the dict is populated. Called from
    /// `showAndStart()` before the first `mount(_:)` so the initial tab gets
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
        // Closing the window with a confirm still up must resolve its owner's pending state —
        // e.g. a quit confirm's `.terminateLater` reply — or the app hangs mid-quit.
        cancelConfirm()
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
