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
    /// Background tabs wanting attention (an OSC 777 agent notification) — each owns a
    /// persistent toast keyed by tab. A tab's rose "waiting" number is derived from this being
    /// present (`waitingToasts[id] != nil`); the toast is the single source of truth. Latched
    /// from a non-active tab; cleared when the tab is shown or closed.
    private var waitingToasts: [TabID: ToastView] = [:]
    private var nextTabID = 1

    /// Process-unique window id, minted once per window from a monotonic counter (never reused, even
    /// after a window closes). `TabID`s are only unique within a window, so OS-notification identity
    /// pairs this with the tab id — see `AgentNotifier`.
    let windowID: Int
    private static var nextWindowID = 1

    /// Opacity of the base-color tint laid over the behind-window blur. 1 = solid shell,
    /// 0 = raw system blur. Tuned for a cohesive shell that still shows depth through the
    /// gutters; the single knob for the whole transparent look. User-overridable via
    /// `backdrop-alpha` in `~/.config/zen-term/config`.
    private static var backdropTintAlpha: CGFloat { GeneralConfig.current.backdropAlpha }

    private let container = NSView()
    /// The base-color tint over the behind-window blur; stored so a `backdrop-alpha` change can
    /// re-tint the running window (see the `configDidChange` observer).
    private let tint = NSView()
    /// Top-right transient notices (e.g. "not a git repository"). Lazy so its stack mounts
    /// above the canvas on first use; window-level so it's shared by every tab.
    private lazy var toasts = ToastPresenter(
        host: container, topInset: ChromeMetrics.windowGutter + 12, trailingInset: ChromeMetrics.windowGutter + 12)

    /// The window's tool floats (ZEN-141). Window-level, not per-tab: one live instance per float
    /// id is shared by every tab, and the card hosts on `container` so a tab switch doesn't
    /// unmount it. Lazy so `container`, `tabBar`, and the tab machinery all exist before the
    /// closures below can run.
    private lazy var floats: ToolFloatController = {
        let controller = ToolFloatController(
            presentOverlay: { [weak self] overlay in self?.presentWindowFloat(overlay) },
            focusedCWD: { [weak self] in self?.activeController?.focusedCWD },
            yieldFocus: { [weak self] in self?.activeController?.yieldFocusToFloat() },
            restoreFocus: { [weak self] in self?.activeController?.restoreUnifiedFocus() })
        controller.onStateChanged = { [weak self] in self?.renderDock() }
        controller.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        return controller
    }()

    private let tabBar: TabBarView
    private let dock: ToggleDock
    private var mountedCanvas: NSView?

    /// Which modal card is open. The repo picker (⌘⇧P), command palette (⌘P), and Add-Workspace
    /// form are mutually exclusive — only one is up at a time — so they share a single slot with
    /// a kind discriminator rather than parallel per-overlay stacks. Window-level (they open/
    /// switch tabs) but presented over the active tab's tile region. Modal while open.
    private enum ModalKind {
        case repoPicker, commandPalette, workspaceForm, settings, toolFloatForm

        /// The chord that closes this same modal when pressed again (its own toggle), or nil for a
        /// card with no dedicated chord (the workspace / tool-float forms, reached from the picker or
        /// a Settings section) — those are still closed by any surface-switch chord in `handle(_:)`,
        /// just not self-toggled.
        var selfToggle: KeyInterceptor.ReservedChord? {
            switch self {
            case .repoPicker: return .toggleRepoPicker
            case .commandPalette: return .toggleCommandPalette
            case .settings: return .openSettings
            case .workspaceForm, .toolFloatForm: return nil
            }
        }
    }
    private var modal: (overlay: ModalOverlay, kind: ModalKind)?

    /// The app's key interceptor, injected so the Settings Keybinds section can capture chords.
    weak var keybindCapturer: KeybindCapturing?

    /// Whether a modal card is up right now. Read by `AppDelegate` so window-level chords (⌘N)
    /// and Copy/Paste routing respect the modal too, not just `handle(_:)`.
    var isModalOverlayOpen: Bool { modal != nil }

    /// A blocking close confirm (⌘W on a busy or last pane), when up. Window-level like
    /// the palettes: modal over the active tab until answered.
    private var confirmToast: ToastView?
    private var confirmOnCancel: (() -> Void)?
    var isConfirmOpen: Bool { confirmToast != nil }

    /// Re-derives tab titles from each tab's live cwd. Shells report cwd changes
    /// without OSC 7, so there's no push event on `cd` — a light poll keeps titles
    /// current; it only re-renders when a title actually changed.
    private var titlePoll: Timer?

    /// Live re-apply for a theme / config change: re-tints the backdrop, re-lays-out every tab
    /// (gutter/gap), re-themes every live terminal surface, and recolors the persistent chrome
    /// (pane borders/halo, tab bar, dock) when a Settings-card edit or a config reload posts
    /// `.configDidChange`. Torn down in `tearDown()`.
    private var configObserver: NSObjectProtocol?

    /// The window has closed (via the last-tab cascade OR the native close button) →
    /// the manager should forget this controller. Fired once, from `windowWillClose`.
    var onClosed: (() -> Void)?

    private var didTearDown = false

    /// The active tab's focused-pane cwd, for `⌘n` new-window inheritance.
    var focusedCWD: URL? { activeController?.focusedCWD }
    var focusedPaneIsVim: Bool { activeController?.focusedPaneIsVim ?? false }

    /// The active tab's controller, or nil once the last tab has closed (the window
    /// is being torn down). Reading `tabs.activeID` on an empty list traps, so every
    /// active-tab access goes through here.
    private var activeController: TabController? {
        guard !tabs.order.isEmpty else { return nil }
        return controllers[tabs.activeID]
    }

    init(contentRect: NSRect, initialCWD: URL?) {
        window = HostWindow(contentRect: contentRect)
        windowID = WindowController.nextWindowID
        WindowController.nextWindowID += 1
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
            onClose: { onClose($0) })
        var onSplitH: () -> Void = {}
        var onSplitV: () -> Void = {}
        var onPalette: () -> Void = {}
        var onBottom: () -> Void = {}
        var onRight: () -> Void = {}
        var onZoom: () -> Void = {}
        var onToolFloat: (ToolFloat) -> Void = { _ in }
        dock = ToggleDock(
            onNewTab: { onNewTab() },
            onSplitH: { onSplitH() }, onSplitV: { onSplitV() },
            onPalette: { onPalette() }, onBottom: { onBottom() },
            onRight: { onRight() }, onZoom: { onZoom() },
            toolFloats: ToolFloatCatalog.all, onToolFloat: { onToolFloat($0) })
        super.init()
        nextTabID = 2

        onSelect = { [weak self] in self?.select($0) }
        onClose = { [weak self] in self?.closeTab($0) }
        // New-tab is a top-level action (like new window) — it acts even while a modal card or
        // float is up, matching the pre-move tab-bar "+", rather than being swallowed by the card
        // gate in handle(_:).
        onNewTab = { [weak self] in self?.newTab() }
        // Dock buttons route through `handle(_:)` (not the tab directly) so they obey the
        // same modal gates as the keyboard chords.
        onSplitH = { [weak self] in self?.handle(.splitHorizontal) }
        onSplitV = { [weak self] in self?.handle(.splitVertical) }
        onPalette = { [weak self] in self?.handle(.toggleCommandPalette) }
        onBottom = { [weak self] in self?.handle(.toggleBottomDrawer) }
        onRight = { [weak self] in self?.handle(.toggleRightDrawer) }
        onZoom = { [weak self] in self?.handle(.toggleZoom) }
        onToolFloat = { [weak self] spec in self?.handle(.toggleToolFloat(spec.id)) }

        let first = makeController(cwd: initialCWD)
        controllers[firstID] = first
        titles[firstID] = first.title

        layoutContainer()
        window.delegate = self  // for windowWillClose teardown (native close button + cascade)

        // Layout & Motion knobs (backdrop tint, window gutter, pane gap) re-apply live: a
        // Settings-card edit re-tints the backdrop and re-lays-out every built tab, no relaunch.
        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.tint.layer?.backgroundColor =
                Theme.current.chrome.background.nsColor.withAlphaComponent(Self.backdropTintAlpha).cgColor
            for controller in self.controllers.values {
                controller.reapplyChromeLayout()
                controller.reapplyChromeColors()
            }
            self.floats.reapplyTheme()
            for surface in self.controllers.values.flatMap({ $0.allSurfaces }) + self.floats.allSurfaces {
                surface.applyAppearance(
                    theme: Theme.current.terminal, behavior: GeneralConfig.current.terminalBehavior)
            }
            self.tabBar.reapplyTheme()
            // A float add / edit / remove changes the catalog — rebuild the dock's per-float buttons
            // (not just recolor) so the toolbar reflects it live, then restore active states. Prune
            // the float registry against the same catalog: a deleted float's hidden process would
            // otherwise keep running with no control able to ever reach it.
            self.floats.prune(against: ToolFloatCatalog.all)
            self.dock.setToolFloats(ToolFloatCatalog.all)
            self.dock.reapplyTheme()
            self.renderDock()
            self.modal?.overlay.reapplyTheme()
            self.confirmToast?.reapplyTheme()
        }
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

        tint.frame = content.bounds
        tint.wantsLayer = true
        tint.layer?.backgroundColor =
            Theme.current.chrome.background.nsColor.withAlphaComponent(Self.backdropTintAlpha).cgColor
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)

        container.frame = content.bounds
        container.autoresizingMask = [.width, .height]
        // Layer-back the container for the same reason the tabs' `content` is: a tool-float card
        // hosted here (ZEN-141) is layer-backed, and one dropped into a non-layer-backed parent
        // after layout doesn't render its drop shadow.
        container.wantsLayer = true
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

        // The active tab's drawer busy-state has no push event, so poll it here (building the
        // overlay once) and re-render the dock only when a drawer's activity dot flips (ZEN-107).
        let overlay = activeController?.overlayState
        let busy = (overlay?.bottomBusy ?? false, overlay?.rightBusy ?? false)
        if busy != lastDrawerBusy { renderDock() }
    }

    /// The active tab's (bottom, right) drawer busy-state as of the last `renderDock()` — so the
    /// poll re-renders only when the activity dot actually flips. Updated on every dock render
    /// (including tab switches), so a switch to a differently-busy tab can't leave it stale.
    private var lastDrawerBusy = (false, false)

    deinit { titlePoll?.invalidate() }  // backstop; tearDown() normally handles it

    // MARK: controller factory

    private func makeController(cwd: URL?, workspace ws: Workspace? = nil) -> TabController {
        // A workspace recipe drives the layout: `main` seeds the primary pane (the sentinel
        // `shell`, like an absent value, means a plain shell), `right`/`bottom` become the
        // drawer commands `applyRecipe` reveals after `start()`, and `env` is injected into
        // every surface. A plain tab (⌘t / first tab) passes no workspace → a bare shell.
        let mainCommand = ws?.main.flatMap { $0 == "shell" ? nil : $0 }
        let c = TabController(
            initialCWD: cwd, initialCommand: mainCommand, env: ws?.env ?? [:],
            isToolFloatOpen: { [weak self] in self?.floats.isOpen ?? false })
        c.rightDrawerCommand = ws?.right
        c.bottomDrawerCommand = ws?.bottom
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
            restoreFocusToActive()  // same canvas: just refresh focus/dock
            renderDock()
            return
        }
        let outgoing = mountedCanvas
        pinCanvas(c.view)
        mountedCanvas = c.view
        restoreFocusToActive()  // a shown float keeps focus; it rides the tab switch
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

    /// Hand keyboard focus back to whatever should hold it: the shown tool float, else the active
    /// tab's focused panel. The float wins because it's modal over the window — without this, a
    /// tab switch or a dismissed modal card would steal first responder to the pane sitting behind
    /// a still-visible card.
    private func restoreFocusToActive() {
        if floats.isOpen { floats.refocus() } else { activeController?.restoreKeyFocus() }
    }

    /// Host a tool-float card at window level, over the active tab's tile region (ZEN-141).
    ///
    /// Hosting on `container` — the same window-level layer `ToastPresenter` uses — rather than
    /// the active tab's `presentTileOverlay` is the whole point: a tab-hosted card unmounts with
    /// its tab, which is exactly why `closeModal()` has to run before any tab-bar op. A float has
    /// to survive a tab switch, so it can't live there.
    ///
    /// The constraints reproduce `presentTileOverlay`'s rect exactly, because `SurfaceFloatOverlay`
    /// resolves its width/height fractions against its OWN bounds — the host rect *is* the
    /// geometry, and a naive pin to `container` would silently resize every float and slide it over
    /// the tab bar. A tab's canvas is `container` minus the tab-bar row (`pinCanvas`), and its
    /// `content` insets that by `windowGutter` on all four sides; this is that composition,
    /// flattened. Inserting below `tabBar` keeps the tab strip and dock clickable, as today.
    private func presentWindowFloat(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .below, relativeTo: tabBar)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ChromeMetrics.windowGutter),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -ChromeMetrics.windowGutter),
            overlay.topAnchor.constraint(equalTo: container.topAnchor, constant: ChromeMetrics.windowGutter),
            overlay.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -ChromeMetrics.windowGutter),
        ])
    }

    // MARK: tab ops

    private func newTab() {
        cancelConfirm()  // the tab-bar "+" is reachable by mouse while a confirm is up
        addTab(cwd: activeController?.focusedCWD, pinnedTitle: nil)
    }

    /// Append a new tab with an explicit cwd and optional pinned title. The `⌘⇧P` picker
    /// passes a `Workspace` (its path + title + open recipe); plain `⌘t` passes the inherited
    /// cwd, no pin, and no workspace (a bare shell).
    private func addTab(cwd: URL?, pinnedTitle: String?, workspace: Workspace? = nil) {
        closeModal()  // the "+" button is reachable while a palette is up
        let id = mintTabID()
        tabs.add(id)
        installController(id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace)
    }

    /// Replace the active tab's controller in place (same tab id/slot) with a fresh session in
    /// `cwd`, pinned to `pinnedTitle` and running `workspace`'s recipe. Used by `⌘⇧P` + Shift+Enter.
    private func replaceActiveTab(cwd: URL, pinnedTitle: String?, workspace: Workspace?) {
        let id = tabs.activeID
        let old = controllers[id]
        if mountedCanvas === old?.view {
            old?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        old?.shutdown()  // terminate the replaced tab's shells — never leak them
        installController(id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace)
    }

    /// Build, wire, mount, and start a controller for `id` (already in `tabs`), applying the
    /// workspace's open recipe when one is given. Shared by new-tab and replace-tab.
    private func installController(id: TabID, cwd: URL?, pinnedTitle: String?, workspace: Workspace?) {
        let c = makeController(cwd: cwd, workspace: workspace)
        c.pinnedTitle = pinnedTitle
        controllers[id] = c
        titles[id] = c.title
        wire(c, id: id)
        mount(.fade)
        c.start()
        if let workspace { c.applyRecipe(workspace) }
        renderTabBar()
    }

    private func select(_ id: TabID, slideFrom: SlideEdge? = nil) {
        closeModal()  // a tab-bar click must not orphan a modal palette
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
        closeModal()  // the "×" button is reachable while a palette is up
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
        // Closing the active tab promotes a neighbor to active; if it was flagged waiting, clear
        // it now — a foreground tab is never "waiting" (and its toast's Switch would be a no-op).
        clearWaiting(tabs.activeID)
        mount(.instant)
        renderTabBar()
    }

    // MARK: modal cards (⌘⇧P picker / ⌘P palette / Add-Workspace form)

    /// Present a modal card over the active tab: mount it, store it in the single slot, focus its
    /// input, and spring it in. One path for all three cards. No-op if there's no active tab.
    private func presentModal(_ overlay: ModalOverlay, kind: ModalKind) {
        guard let active = activeController else { return }
        active.presentTileOverlay(overlay)
        modal = (overlay, kind)
        overlay.focusInitialResponder()
        overlay.animateIn()
        renderDock()  // dock mirrors the new modal state
    }

    /// Close whichever modal card is up: spring it out, clear the slot now (so the modal gate
    /// lifts this turn and a second Esc/toggle is a no-op), and restore keyboard focus to the
    /// tab. No-op when nothing is open. Also called before any tab-bar mouse op (select/new/
    /// close), which would otherwise unmount the card's host tab and leave the gate stuck on.
    private func closeModal() {
        guard let overlay = modal?.overlay else { return }
        modal = nil
        overlay.animateOut { overlay.removeFromSuperview() }
        restoreFocusToActive()
        renderDock()
    }

    /// Toggle the workspace picker (⌘⇧P). Reads the `workspaces` file fresh on each open (so
    /// hand-edits appear without a relaunch). Pressing ⌘⇧P while it's up closes it.
    private func toggleRepoPicker() {
        if modal?.kind == .repoPicker { closeModal(); return }
        let picker = RepoPickerOverlay(
            entries: ConfigLoader.loadWorkspaces(),
            background: Theme.current.chrome.background.nsColor,
            onChoose: { [weak self] ws, replace in self?.openWorkspace(ws, replaceCurrentTab: replace) },
            onAddWorkspace: { [weak self] in self?.openAddWorkspaceForm() },
            onDismiss: { [weak self] in self?.closeModal() }
        )
        presentModal(picker, kind: .repoPicker)
    }

    /// Toggle the command palette (⌘P). Builds the catalog fresh (its tab-select entries track
    /// the live tab count). Pressing ⌘P while it's up closes it.
    private func toggleCommandPalette() {
        if modal?.kind == .commandPalette { closeModal(); return }
        let palette = CommandPaletteOverlay(
            commands: CommandCatalog.commands(tabCount: tabs.order.count),
            background: Theme.current.chrome.background.nsColor,
            onRun: { [weak self] chord in self?.runCommand(chord) },
            onDismiss: { [weak self] in self?.closeModal() }
        )
        presentModal(palette, kind: .commandPalette)
    }

    /// Open the Add-Workspace form from the ⌘⇧P picker's ＋ row. Seeds it with the current titles for
    /// inline collision checks; submitting writes the section and opens it. The picker is still up
    /// when the ＋ fires, so close it first. (Editing / deleting a workspace goes through Settings →
    /// Workspaces instead, via `openWorkspaceForm`.)
    private func openAddWorkspaceForm() {
        closeModal()
        let form = AddWorkspaceOverlay(
            existingTitles: Set(ConfigLoader.loadWorkspaces().map(\.title)),
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { [weak self] ws in self?.submitNewWorkspace(ws) },
            onCancel: { [weak self] in self?.closeModal() }
        )
        presentModal(form, kind: .workspaceForm)
    }

    /// Which section the Settings card opens on. `.tools` / `.workspaces` are used when a sub-form
    /// (tool-float or workspace editor) hands back to the section it was launched from.
    private enum SettingsLanding { case top, tools, workspaces }

    /// Open the Settings card. Built fresh each open so every section reads live config values.
    private func openSettings(landing: SettingsLanding = .top) {
        if modal?.kind == .settings { closeModal(); return }
        let toolsSection = SettingsToolsSection()
        toolsSection.onEditFloat = { [weak self] float in self?.openToolFloatForm(editing: float) }
        let workspacesSection = SettingsWorkspacesSection()
        workspacesSection.onEditWorkspace = { [weak self] ws in self?.openWorkspaceForm(editing: ws) }
        // Sorted by nav title so the nav reads alphabetically and stays ordered as sections are
        // added — the array order is the on-screen order.
        let sections: [SettingsSection] = [
            SettingsAppearanceSection(),
            SettingsNotificationsSection(),
            SettingsTerminalSection(),
            SettingsKeybindsSection(capturer: keybindCapturer),
            toolsSection,
            workspacesSection,
        ].sorted { $0.navTitle.localizedCaseInsensitiveCompare($1.navTitle) == .orderedAscending }
        let landingSection: SettingsSection?
        switch landing {
        case .top: landingSection = nil
        case .tools: landingSection = toolsSection
        case .workspaces: landingSection = workspacesSection
        }
        let overlay = SettingsOverlay(
            sections: sections,
            capturer: keybindCapturer,
            initialSection: landingSection.flatMap { target in sections.firstIndex { $0 === target } } ?? 0,
            background: Theme.current.chrome.background.nsColor,
            onClose: { [weak self] in self?.closeModal() }
        )
        presentModal(overlay, kind: .settings)
    }

    /// Open the tool-float add / edit form from the Tools section (`nil` adds, a value edits). Closes
    /// the Settings card first — one modal slot — mirroring the picker → Add-Workspace hand-off; the
    /// form's own id-collision check excludes the float being edited. On save or cancel it hands back
    /// to Settings → Tools (the section it was launched from).
    private func openToolFloatForm(editing float: ToolFloat?) {
        closeModal()
        let existingIDs = Set(GeneralConfig.current.floats.map(\.id)).subtracting(float.map { [$0.id] } ?? [])
        let originalID = float?.id
        let form = ToolFloatFormOverlay(
            editing: float,
            existingIDs: existingIDs,
            capturer: keybindCapturer,
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { [weak self] built in self?.submitToolFloat(built, replacing: originalID) },
            onCancel: { [weak self] in self?.reopenSettingsOnTools() },
            onDelete: float.map { existing in { [weak self] in self?.deleteToolFloat(existing) } }
        )
        presentModal(form, kind: .toolFloatForm)
    }

    /// Delete the float being edited, reload the live config (dropping its dock button / ⌘P entry /
    /// keybind), then hand back to Settings → Tools. A write failure keeps the form up with a toast.
    private func deleteToolFloat(_ float: ToolFloat) {
        do {
            try ConfigWriter.apply(floatRemovals: [float.id])
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Delete Tool Float",
                    message: "Failed to update the config file: \(error.localizedDescription)"))
            return
        }
        AppConfig.reload()
        reopenSettingsOnTools()
    }

    /// Persist a built tool float (upsert by id), reload the live config so the dock button, ⌘P
    /// entry, and keybind appear with no restart, then hand back to Settings → Tools. A write failure
    /// keeps the form up with a toast. `originalID` is the id before an edit — when a rename changed
    /// it, the old line is removed in the same write so the float moves rather than duplicating.
    private func submitToolFloat(_ float: ToolFloat, replacing originalID: String?) {
        let removals: Set<String> = (originalID.map { $0 != float.id ? [$0] : [] }) ?? []
        do {
            try ConfigWriter.apply(floatUpserts: [float], floatRemovals: removals)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Save Tool Float",
                    message: "Failed to write \(float.id) to the config file: \(error.localizedDescription)"))
            return
        }
        AppConfig.reload()
        reopenSettingsOnTools()
    }

    /// Close the tool-float form and reopen the Settings card on its Tools section — the "back" for
    /// the sub-form, so save / cancel land where the user launched it.
    private func reopenSettingsOnTools() {
        closeModal()
        openSettings(landing: .tools)
    }

    /// Open the workspace add / edit form from the Settings → Workspaces section (`nil` adds, a value
    /// edits). Closes the Settings card first — one modal slot — mirroring the tool-float hand-off;
    /// the form's own title-collision check excludes the workspace being edited. On save / cancel /
    /// delete it hands back to Settings → Workspaces.
    private func openWorkspaceForm(editing workspace: Workspace?) {
        closeModal()
        let existingTitles = Set(ConfigLoader.loadWorkspaces().map(\.title))
            .subtracting(workspace.map { [$0.title] } ?? [])
        let originalTitle = workspace?.title
        let form = AddWorkspaceOverlay(
            editing: workspace,
            existingTitles: existingTitles,
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { [weak self] built in self?.submitWorkspace(built, replacing: originalTitle) },
            onCancel: { [weak self] in self?.reopenSettingsOnWorkspaces() },
            onDelete: workspace.map { existing in { [weak self] in self?.deleteWorkspace(existing) } }
        )
        presentModal(form, kind: .workspaceForm)
    }

    /// Persist a workspace edited / added from Settings, then hand back to Settings → Workspaces (the
    /// ⌘⇧P picker reads the file fresh on each open, so no reload is needed for it to reflect this).
    /// `originalTitle` is the title before an edit — a rename replaces that section in place; a nil
    /// original is a fresh add. A write failure keeps the form up with a toast.
    private func submitWorkspace(_ ws: Workspace, replacing originalTitle: String?) {
        do {
            if let originalTitle {
                try WorkspacesWriter.update(ws, originalTitle: originalTitle)
            } else {
                try WorkspacesWriter.append(ws)
            }
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Save Workspace",
                    message: "Failed to write \(ws.title) to the workspaces file: \(error.localizedDescription)"))
            return
        }
        reopenSettingsOnWorkspaces()
    }

    /// Delete the workspace being edited, then hand back to Settings → Workspaces. A write failure
    /// keeps the form up with a toast.
    private func deleteWorkspace(_ ws: Workspace) {
        do {
            try WorkspacesWriter.remove(title: ws.title)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Delete Workspace",
                    message: "Failed to update the workspaces file: \(error.localizedDescription)"))
            return
        }
        reopenSettingsOnWorkspaces()
    }

    /// Close the workspace form and reopen the Settings card on its Workspaces section — the "back"
    /// for the sub-form, so save / cancel / delete land where the user launched it.
    private func reopenSettingsOnWorkspaces() {
        closeModal()
        openSettings(landing: .workspaces)
    }

    /// Persist a freshly-built workspace, then open it. On a write failure the form stays up and
    /// a toast explains why; on success the form closes and the workspace opens in a new tab
    /// (the value-based `openWorkspace` seam — no relaunch, no dependence on a launch-time store).
    private func submitNewWorkspace(_ ws: Workspace) {
        do {
            try WorkspacesWriter.append(ws)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Save Workspace",
                    message: "Failed to write \(ws.title) to the workspaces file: \(error.localizedDescription)"))
            return
        }
        closeModal()
        openWorkspace(ws, replaceCurrentTab: false)
    }

    /// Run a chosen command: close the palette first (clears its modal gate), then dispatch
    /// the chord through the normal `handle(_:)` path — including `.toggleRepoPicker`, which
    /// opens the repo picker once the palette is gone.
    private func runCommand(_ chord: KeyInterceptor.ReservedChord) {
        closeModal()
        handle(chord)
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
        closeModal()  // never stack over an open palette
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
        restoreFocusToActive()  // hand focus back to the pane (or the float over it)
        renderDock()
    }

    /// Open a workspace: a new tab (Enter) or by replacing the current tab (Shift+Enter). The
    /// tab is pinned to the workspace title so it survives the focused pane's cwd changes, and
    /// its open recipe (drawers + focus + env) is applied by `installController`. Takes a
    /// `Workspace` value, not a store lookup — so a freshly-built one (a future in-app "Add
    /// Workspace" form) can open immediately without a relaunch; that form will widen access then.
    private func openWorkspace(_ ws: Workspace, replaceCurrentTab: Bool) {
        closeModal()
        if replaceCurrentTab {
            replaceActiveTab(cwd: ws.path, pinnedTitle: ws.title, workspace: ws)
        } else {
            addTab(cwd: ws.path, pinnedTitle: ws.title, workspace: ws)
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
        // A modal card (repo picker / command palette / Add-Workspace form) is modal over the
        // window: its own toggle closes it, another surface's toggle (another card, a tool
        // float) closes it and opens that instead — a live switch between all the modal
        // cards; every other chord is swallowed. Its arrow/Enter/Esc keys aren't chords — they
        // go to the card's field editor, never here.
        if let modal {
            if let selfToggle = modal.kind.selfToggle, chord == selfToggle {
                closeModal()
                return
            }
            switch chord {
            case .toggleRepoPicker, .toggleCommandPalette, .openSettings, .toggleToolFloat:
                closeModal()  // close the current card, then open the requested surface below
            default:
                return
            }
        }
        // A tool float is modal over the window: its own toggle closes it (another float's toggle
        // switches — `floats.toggle` handles both), a modal card's toggle closes it and opens
        // that instead, ⌘W is guarded with a brief note (it never reaches the pane behind the
        // float); split/nav/drawer/zoom are swallowed; cross-tab/window chords still act — the
        // card is window-hosted, so it rides a tab switch instead of unmounting with its tab.
        if floats.isOpen {
            switch chord {
            case .closePane:
                let name =
                    floats.activeID.flatMap(ToolFloatCatalog.byID)
                    .map { $0.title.replacingOccurrences(of: "Open ", with: "") } ?? "the tool"
                toasts.show(
                    ToastContent(
                        variant: .info, title: "Close Pane",
                        message: "Close \(name) first to close a pane."))
                return
            case .toggleCommandPalette, .toggleRepoPicker, .openSettings:
                floats.close()  // close it, then fall through to open the other
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
        case .newWindow, .reloadConfig:
            break  // handled by AppDelegate (window manager / app-global config reload); no-op here
        case .toggleBottomDrawer: active?.toggleBottomDrawer()
        case .toggleRightDrawer: active?.toggleRightDrawer()
        case .toggleZoom: active?.toggleZoom()
        case .toggleToolFloat(let id):
            if let spec = ToolFloatCatalog.byID(id) { floats.toggle(spec) }
        case .toggleRepoPicker: toggleRepoPicker()
        case .toggleCommandPalette: toggleCommandPalette()
        case .openSettings: openSettings()
        }
    }

    /// Number of open tabs in this window (for the quit tally).
    var tabCount: Int { tabs.order.count }

    /// Bring `id` to the front (banner-click routing). Public wrapper over the private `select`.
    func selectTab(_ id: TabID) { select(id) }

    /// The app regained focus: this window's frontmost (active) tab is now on screen, so drop any OS
    /// banner pushed for it while unfocused. `clearWaiting` never fires for the active tab (it's never
    /// re-`select`ed), so this closes that gap; background tabs keep their banners until visited.
    func clearActiveTabNotification() {
        // Reading `tabs.activeID` traps on an empty list; a window between last-tab-close and
        // `windowWillClose` is still in `AppDelegate.windows`, so guard before touching it.
        guard !tabs.order.isEmpty else { return }
        AgentNotifier.shared.clear(windowID: windowID, tabID: tabs.activeID)
    }

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

        // Only the last-pane path consults drawers and hidden persistent floats, so probe them
        // lazily. Hidden floats matter precisely because they're invisible: a dismissed
        // `persist:` tool keeps running with no on-screen trace, and this confirm is the only
        // thing standing between ⌘W and silently killing its live work. Floats are window-wide
        // (ZEN-141), so this now sees one opened from any tab, not just the active one.
        let running = lastPane ? (busy || active.hasBusyDrawer || floats.hasBusy) : busy
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

    // MARK: copy/paste — routed to the shown tool float, else the active tab's controller

    // A shown float is modal over the window, so it owns the clipboard verbs; a persistent float's
    // surface outlives its card, so gate on visibility (`isOpen`), not on the registry.
    @objc func copyFromSurface(_ sender: Any?) {
        if floats.isOpen { floats.copyFromSurface(sender) } else { activeController?.copyFromSurface(sender) }
    }
    @objc func pasteToSurface(_ sender: Any?) {
        if floats.isOpen { floats.pasteToSurface(sender) } else { activeController?.pasteToSurface(sender) }
    }

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
        c.onPaneStartFailed = { [weak self] retry, close in
            self?.presentSurfaceFailureToast(retry: retry, close: close)
        }
        // A pane click while a close confirm is up moves the confirm's target — void it.
        c.onFocusChanged = { [weak self] in self?.cancelConfirm() }
        c.onNotification = { [weak self] n in self?.agentNotified(id: id, notification: n) }
    }

    /// A background tab posted an OSC 777 desktop notification (e.g. an agent asking for
    /// permission or waiting for input) → flag its number rose and show the notification's own
    /// message, unless it's the tab you're already looking at. A repeat refreshes the toast in
    /// place, so "needs permission" updates to "waiting for input" without stacking.
    private func agentNotified(id: TabID, notification: TerminalNotification) {
        // The notification arrives off the terminal's read path; only touch the UI on main.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabs.order.contains(id) else { return }
            let message = notification.body.isEmpty ? notification.title : notification.body

            // OS banner: fires for ANY tab — even the frontmost one — whenever the app is unfocused,
            // covering the "I walked away" case the in-app toast can't (the toast is invisible when
            // we're not frontmost). Gated by app focus + the setting; delivery is a no-op without the
            // macOS permission.
            if AgentNotifier.shouldPushNotification(
                appActive: NSApp.isActive, enabled: GeneralConfig.current.agentNotifications)
            {
                AgentNotifier.shared.notify(
                    windowID: self.windowID, tabID: id, title: self.titles[id] ?? "shell", body: message)
            }

            // In-app toast: background tabs only — a sticky notice on the tab you're already looking at
            // would be noise.
            guard id != self.tabs.activeID else { return }
            let wasWaiting = self.waitingToasts[id] != nil
            self.presentWaitingToast(for: id, message: message)
            if !wasWaiting { self.renderTabBar() }  // first flag → recolor the number
        }
    }

    /// Show (or replace) the persistent, non-modal attention toast for a background tab. The
    /// title is the tab's name. It answers only through its buttons — "Switch" jumps to the
    /// tab, "Dismiss" clears the notice — and visiting the tab any other way clears it too.
    private func presentWaitingToast(for id: TabID, message: String) {
        if let old = waitingToasts[id] { toasts.dismiss(old) }  // replace any prior toast for this tab
        let content = ToastContent(
            variant: .info, title: titles[id] ?? "shell", message: message, icon: "bell.fill")
        // Match the confirm-dialog convention: muted secondary action on the left, primary on
        // the right (Dismiss, then Switch).
        let actions = [
            ToastAction(title: "Dismiss", kind: .cancel) { [weak self] in
                guard let self else { return }
                self.clearWaiting(id)
                self.renderTabBar()  // "Dismiss" also drops the rose flag
            },
            ToastAction(title: "Switch", kind: .destructive) { [weak self] in self?.select(id) },
        ]
        waitingToasts[id] = toasts.showSticky(content, actions: actions)
    }

    /// A pane's surface failed to start: show a sticky, non-modal notice offering to retry the
    /// launch or close the dead pane. Each button starts the toast's (asynchronous) dismiss and
    /// then runs its action; a failed retry re-fires this path with a fresh toast. Both roles are
    /// theme-driven via the `.warning` variant, so no color is hardcoded.
    private func presentSurfaceFailureToast(retry: @escaping () -> Void, close: @escaping () -> Void) {
        let content = ToastContent(
            variant: .warning, title: "Terminal Didn't Start",
            message: "The terminal surface failed to launch.")
        var toast: ToastView?
        let actions = [
            ToastAction(title: "Close Pane", kind: .cancel) { [weak self] in
                if let toast { self?.toasts.dismiss(toast) }
                close()
            },
            ToastAction(title: "Retry", kind: .destructive) { [weak self] in
                if let toast { self?.toasts.dismiss(toast) }
                retry()
            },
        ]
        toast = toasts.showSticky(content, actions: actions)
    }

    /// Test hook: drive the real surface-failure toast so a test can click its actual buttons.
    func presentSurfaceFailureToastForTesting(retry: @escaping () -> Void, close: @escaping () -> Void) {
        presentSurfaceFailureToast(retry: retry, close: close)
    }

    /// Clear a tab's waiting state: dismiss its toast — which also drops the rose flag, since
    /// the flag is derived from the toast's presence (`waitingToasts[id] != nil`). Called when
    /// the tab is shown or closed. Re-render is left to the caller (all callers already do).
    private func clearWaiting(_ id: TabID) {
        if let toast = waitingToasts.removeValue(forKey: id) { toasts.dismiss(toast) }
        AgentNotifier.shared.clear(windowID: windowID, tabID: id)  // also drop any OS banner for this tab
    }

    private func renderTabBar() {
        let items = tabs.order.enumerated().map { i, id in
            TabBarItem(
                id: id, index: i + 1,
                title: titles[id] ?? "shell",
                isActive: id == tabs.activeID,
                agentState: waitingToasts[id] != nil ? .waiting : .idle)
        }
        tabBar.render(items)
    }

    /// Mirror the active tab's overlay state + the window's command-palette state onto the
    /// dock's active tints. Called on tab switch, overlay toggles, and palette open/close.
    private func renderDock() {
        let overlay = activeController?.overlayState ?? OverlayState()
        // The shown float is window-level, so it comes from `floats`, not the active tab's state.
        dock.render(overlay: overlay, floatID: floats.activeID, paletteOpen: modal?.kind == .commandPalette)
        // Keep the poll's change-guard in sync with what's actually shown, so a tab switch to a
        // differently-busy tab re-evaluates instead of comparing against a stale value.
        lastDrawerBusy = (overlay.bottomBusy, overlay.rightBusy)
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
        // The keybind interceptor is shared app-wide. Closing this window while a Settings capture
        // is armed (a native red-button close is a mouse event the capture can't intercept) would
        // otherwise strand it in capture mode — swallowing every keystroke in every other window.
        keybindCapturer?.endCapture()
        titlePoll?.invalidate()
        titlePoll = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        floats.shutdown()  // the window owns its floats, including the hidden persistent ones
        for c in controllers.values { c.shutdown() }
        controllers.removeAll()
        onClosed?()
    }
}

extension WindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { tearDown() }
}
