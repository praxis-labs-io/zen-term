import AppKit
import AppLog
import TabKit
import TerminalKit
import UniformTypeIdentifiers

@MainActor
final class WindowController: NSObject {
    let window: HostWindow

    private var tabs: TabList
    private var controllers: [TabID: TabController] = [:]
    private var titles: [TabID: String] = [:]
    private var attentionToasts: [TabID: ToastView] = [:]
    private var attentionStates: [TabID: TabAttentionState] = [:]
    private static let commandCompletionThreshold: TimeInterval = 10
    private var nextTabID = 1

    // `TabID`s are unique only within a window, so notification identity pairs this with the tab id.
    let windowID: Int
    private static var nextWindowID = 1

    private static var backdropTintAlpha: CGFloat { GeneralConfig.current.backdropAlpha }

    private let container = NSView()
    private let tint = NSView()
    // Built on first use so the stack mounts above the canvas; not `lazy`, so re-insetting can't construct one.
    private var builtToasts: ToastPresenter?
    private var toasts: ToastPresenter {
        if let builtToasts { return builtToasts }
        let presenter = ToastPresenter(
            host: container, below: modal?.overlay, topInset: Self.toastTopInset,
            trailingInset: Self.toastTrailingInset, dismissAfter: GeneralConfig.current.toastDuration)
        builtToasts = presenter
        return presenter
    }

    private static var toastTopInset: CGFloat { ChromeMetrics.topInset + 12 }
    private static var toastTrailingInset: CGFloat { ChromeMetrics.windowGutter + 12 }

    func showToast(_ content: ToastContent) { toasts.show(content) }

    private var fontSizeCard: FontSizeCard?
    private var fontSizeDismissal: DispatchWorkItem?
    private static let fontSizeCardLinger: TimeInterval = 1.2

    func showFontSize(_ text: String) {
        if let card = fontSizeCard {
            card.update(text: text)
        } else {
            let card = FontSizeCard(text: text)
            fontSizeCard = card
            toasts.present(card: card)
        }
        fontSizeDismissal?.cancel()
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissFontSizeCard() }
        fontSizeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fontSizeCardLinger, execute: dismissal)
    }

    private func dismissFontSizeCard() {
        guard let card = fontSizeCard else { return }
        fontSizeCard = nil
        fontSizeDismissal = nil
        toasts.remove(card: card)
    }

    // Separate from `applyAppearance`: once a surface has an explicit size, libghostty stops applying config reloads to its font.
    func applySessionFontSize() {
        for surface in allTerminalSurfaces { surface.setFontSize(SessionFontSize.points) }
        scrollMode.refreshGeometry()
    }

    private var allTerminalSurfaces: [TerminalSurface] {
        controllers.values.flatMap { $0.allSurfaces } + floats.allSurfaces
    }

    /// Fans a modifier move out to the visible surfaces, which the responder chain reaches only one
    /// of. Each surface drops the event if it already took it, so the first responder is included.
    func modifiersDidChange(_ event: NSEvent) {
        for surface in visibleTerminalSurfaces { surface.modifiersDidChange(event) }
    }

    // Background tabs are excluded: nothing of theirs is on screen for a modifier to change.
    private var visibleTerminalSurfaces: [TerminalSurface] {
        (activeController?.allSurfaces ?? []) + floats.allSurfaces
    }

    func presentUpdateCard(_ card: UpdateCardView) { toasts.present(card: card) }

    func dismissUpdateCard(_ card: UpdateCardView) {
        card.beginDismissal()
        toasts.remove(card: card)
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "ZenTerm Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let builder = DiagnosticsBundleBuilder(
                    report: .current(), logFiles: Log.fileSink?.fileURLs ?? [])
                do {
                    try builder.build(to: destination)
                    Log.info("diagnostics exported to \(destination.lastPathComponent)", category: .app)
                    DispatchQueue.main.async {
                        self.showToast(
                            ToastContent(
                                variant: .positive, title: "Diagnostics Exported",
                                message:
                                    "Saved \(destination.lastPathComponent). It holds your logs and system info."
                            ))
                    }
                } catch {
                    Log.error("diagnostics export failed: \(error.localizedDescription)", category: .app)
                    DispatchQueue.main.async {
                        self.showToast(
                            ToastContent(
                                variant: .warning, title: "Export Failed",
                                message: "Couldn't write the diagnostics file: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    // Lazy so `container`, `tabBar` and the tab machinery exist before its closures run.
    private lazy var floats: ToolFloatController = {
        let controller = ToolFloatController(
            presentOverlay: { [weak self] overlay in self?.presentWindowFloat(overlay) },
            focusedCWD: { [weak self] in self?.activeController?.focusedCWD },
            yieldFocus: { [weak self] in
                self?.endModes()
                self?.activeController?.yieldFocusToFloat()
            },
            restoreFocus: { [weak self] in self?.activeController?.restoreUnifiedFocus() },
            currentTabID: { [weak self] in
                guard let self, !self.tabs.order.isEmpty else { return nil }
                return self.tabs.activeID
            })
        controller.onStateChanged = { [weak self] in self?.renderDock() }
        controller.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        controller.onNotification = { [weak self] n, spec, owner in
            self?.floatNotified(n, from: spec, owner: owner)
        }
        controller.onSurfaceEvent = { [weak self] surface, event in self?.report(surface, event) }
        return controller
    }()

    private var floatGutter:
        (
            leading: NSLayoutConstraint, trailing: NSLayoutConstraint, top: NSLayoutConstraint,
            bottom: NSLayoutConstraint
        )?

    private var closingModalKind: ModalKind?

    // Kept beside the card so a form replacing another inherits its way back.
    private var toolFormReturn: ToolFormReturn?

    private var modalGutter:
        (
            leading: NSLayoutConstraint, trailing: NSLayoutConstraint, top: NSLayoutConstraint,
            bottom: NSLayoutConstraint
        )?

    private let tabBar: TabBarView
    private let dock: ToggleDock
    private var mountedCanvas: NSView?

    private enum ModalKind {
        case repoPicker, commandPalette, workspaceForm, settings, toolFloatForm, reportIssue
        case renameTab, worktreeForm

        var selfToggle: KeyInterceptor.ReservedChord? {
            switch self {
            case .repoPicker: return .toggleRepoPicker
            case .commandPalette: return .toggleCommandPalette
            case .settings: return .openSettings
            case .workspaceForm, .toolFloatForm, .reportIssue, .renameTab, .worktreeForm:
                return nil
            }
        }
    }
    private var modal: (overlay: ModalOverlay, kind: ModalKind)?

    // The only trace of a card still loading: stops a second press presenting twice, or a late load presenting after Esc.
    private var pendingModal: ModalKind?

    weak var keybindCapturer: KeybindCapturing?

    weak var keyModeHost: KeyModeHosting?

    let scrollMode = ScrollModeController()

    lazy var search = SearchController(scrollMode: scrollMode)

    // A palette pick reaches `handle` directly, past `AppDelegate.route`, so app-global chords come back through here.
    var onAppGlobalCommand: ((KeyInterceptor.ReservedChord) -> Void)?

    var onCountTabsAtPath: ((URL) -> Int)?

    var worktreeRemovals = WorktreeRemovalTracker()

    func tabCount(atPath path: URL) -> Int {
        tabs.order.filter { Self.isInside(controllers[$0]?.openedCWD, path) }.count
    }

    private static func isInside(_ cwd: URL?, _ root: URL) -> Bool {
        guard let cwd = cwd?.standardizedFileURL.path else { return false }
        let target = root.standardizedFileURL.path
        return cwd == target || cwd.hasPrefix(target.hasSuffix("/") ? target : target + "/")
    }

    // An open card keeps the keyboard: the picker is where the user watches the removal.
    func closeTabs(atPath path: URL) {
        let card = modal?.overlay
        for id in tabs.order where Self.isInside(controllers[id]?.openedCWD, path) {
            closeTab(id, dismissingModal: false)
        }
        if let card, modal?.overlay === card { card.focusInitialResponder() }
    }

    // Tabs close only once the folder is gone, or the last one takes the window and its progress picker with it.
    func worktreeRemovalsChanged(_ change: WorktreeRemovalTracker.Change) {
        if case .removed(let path) = change { closeTabs(atPath: path) }
        guard let picker = modal?.overlay as? RepoPickerOverlay else { return }
        switch change {
        case .began: picker.refreshRemovalState()
        case .removed(let path): picker.dropWorktree(at: path); picker.relistWorktrees()
        case .failed: picker.refreshRemovalState(); picker.relistWorktrees()
        }
    }

    var isModalOverlayOpen: Bool { modal != nil }

    private var confirmToast: ToastView?
    private var confirmOnCancel: (() -> Void)?
    var isConfirmOpen: Bool { confirmToast != nil }

    // Polled because shells report cwd without OSC 7, so a `cd` sends no event.
    private var titlePoll: Timer?

    private var configObserver: NSObjectProtocol?

    var onClosed: (() -> Void)?

    private var didTearDown = false

    var focusedCWD: URL? { activeController?.focusedCWD }
    var focusedPaneIsVim: Bool { activeController?.focusedPaneIsVim ?? false }

    var isToolFloatOpen: Bool { floats.isOpen }

    var isRepoPickerOpen: Bool { modal?.kind == .repoPicker }

    private var activeFloatName: String? {
        floats.activeID.flatMap(ToolFloatCatalog.byID)
            .map { $0.title.replacingOccurrences(of: "Open ", with: "") }
    }

    // Held chords auto-repeat; without this a leaned-on chord stacks a card per keystroke.
    private static let floatBlockToastThrottle: TimeInterval = 3
    private var lastFloatBlockToast: Date?

    private func toastFloatBlocked() {
        let now = Date()
        if let last = lastFloatBlockToast,
            now.timeIntervalSince(last) < Self.floatBlockToastThrottle
        {
            return
        }
        lastFloatBlockToast = now
        toasts.show(
            ToastContent(
                variant: .info, title: "Tool Float",
                message: "\(activeFloatName ?? "This tool") is open. Close it to get back to your panes."))
    }

    // `tabs.activeID` traps on an empty list, so every active-tab read goes through here.
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
        var onSelect: (TabID) -> Void = { _ in }
        var onClose: (TabID) -> Void = { _ in }
        var onRename: (TabID) -> Void = { _ in }
        var onNewTab: () -> Void = {}
        tabBar = TabBarView(
            onSelect: { onSelect($0) },
            onClose: { onClose($0) },
            onRename: { onRename($0) })
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
            toolFloats: ToolFloatCatalog.userDefined, onToolFloat: { onToolFloat($0) },
            hiddenButtons: GeneralConfig.current.hiddenToolbarButtons)
        super.init()
        nextTabID = 2

        onSelect = { [weak self] in self?.select($0) }
        onClose = { [weak self] in self?.closeTab($0) }
        onRename = { [weak self] in self?.openRenameTab($0) }
        onNewTab = { [weak self] in self?.newTab() }
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
        window.delegate = self
        wireModes()

        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let change = ConfigChange.from(note)

                if change.contains(.theme) || change.contains(.chromeLayout) {
                    self.tint.layer?.backgroundColor =
                        Theme.current.chrome.background.nsColor.withAlphaComponent(Self.backdropTintAlpha)
                        .cgColor
                }
                if change.contains(.chromeLayout) {
                    self.window.setWindowChromeVisible(GeneralConfig.current.windowChrome)
                    for controller in self.controllers.values { controller.reapplyChromeLayout() }
                    self.reapplyFloatLayout()
                    self.reapplyModalLayout()
                    self.builtToasts?.reapplyInsets(
                        topInset: Self.toastTopInset, trailingInset: Self.toastTrailingInset)
                }
                if change.contains(.theme) || change.contains(.keymap)
                    || change.contains(.terminalBehavior)
                {
                    for controller in self.controllers.values { controller.reapplyChromeColors() }
                }
                if change.contains(.theme) || change.contains(.terminalBehavior) {
                    self.floats.reapplyTheme()
                }
                if change.contains(.theme) {
                    self.tabBar.reapplyTheme()
                    self.dock.reapplyTheme()
                    self.confirmToast?.reapplyTheme()
                    self.attentionToasts.values.forEach { $0.reapplyTheme() }
                    self.fontSizeCard?.reapplyTheme()
                }
                if change.contains(.toasts) {
                    self.builtToasts?.reapplyDuration(GeneralConfig.current.toastDuration)
                }
                if change.contains(.theme) || change.contains(.terminalBehavior) {
                    for surface in self.allTerminalSurfaces {
                        surface.applyAppearance(
                            theme: Theme.current.terminal, behavior: GeneralConfig.current.terminalBehavior)
                    }
                    self.applySessionFontSize()
                }
                if change.contains(.floats) {
                    self.floats.prune(against: ToolFloatCatalog.all)
                    self.dock.setToolFloats(ToolFloatCatalog.userDefined)
                    self.dock.reapplyTheme()
                    self.renderDock()
                }
                if change.contains(.toolbarButtons) {
                    self.dock.setHiddenButtons(GeneralConfig.current.hiddenToolbarButtons)
                    self.renderDock()
                }
                if change.contains(.theme) || change.contains(.keymap) || change.contains(.floats) {
                    self.modal?.overlay.reapplyTheme()
                }
            }
        }
    }

    private func layoutContainer() {
        let content = window.contentView!

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
            dock.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            dock.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor, constant: -6),
            tabBar.trailingAnchor.constraint(equalTo: dock.leadingAnchor, constant: -8),
        ])
    }

    private func toggleScrollMode() {
        if search.isEditing {
            search.commit()
            return
        }
        if scrollMode.isActive {
            scrollMode.end()
            return
        }
        guard let target = modeTarget else { return }
        scrollMode.begin(surface: target.surface, panel: target.host)
    }

    private func toggleSearch() {
        guard let target = modeTarget else { return }
        let selected = scrollMode.selectedText ?? target.surface.copySelection()
        search.begin(surface: target.surface, panel: target.host, seed: selected ?? "")
    }

    private func searchSelection() {
        guard let target = modeTarget else { return }
        guard let selected = scrollMode.selectedText ?? target.surface.copySelection(),
            !selected.isEmpty
        else { return }
        search.begin(surface: target.surface, panel: target.host, seed: selected)
    }

    private var modeTarget: (surface: TerminalSurface, host: TerminalModeHost)? {
        if let shown = floats.shownTarget { return shown }
        guard let panel = activeController?.focusedScrollTarget else { return nil }
        return (panel.surface, panel.panel)
    }

    private func scrollFocusedPane(_ command: TerminalScroll) {
        modeTarget?.surface.scroll(command)
    }

    // Not the pasteboard: ghostty's `paste_from_selection` means the X11 selection clipboard, which macOS lacks.
    private func pasteSelection() {
        guard let target = modeTarget else { return }
        guard let selected = scrollMode.selectedText ?? target.surface.copySelection(),
            !selected.isEmpty
        else { return }
        target.surface.paste(selected)
    }

    private func report(_ surface: TerminalSurface, _ event: SurfaceEvent) {
        switch event {
        case .scrollPosition(let position):
            scrollMode.report(position: position, from: surface)
            search.report(position: position, from: surface)
        case .gridReflow:
            scrollMode.reportReflow(from: surface)
        case .search(let event):
            search.handle(event, from: surface, panel: modeTarget?.host)
        }
    }

    // Search ends first because taking the bar down reflows the grid scroll mode measures against.
    private func endModes() {
        search.end()
        scrollMode.end()
    }

    private func wireModes() {
        scrollMode.onSearchWord = { [weak self] word in
            guard let target = self?.modeTarget else { return }
            self?.search.begin(surface: target.surface, panel: target.host, seed: word)
        }
        scrollMode.onActiveChanged = { [weak self] active in
            guard let self else { return }
            if !active { self.search.end() }
            self.updateModeHandler()
        }
        search.onActiveChanged = { [weak self] _ in self?.updateModeHandler() }
    }

    // Stands down while the find field holds focus, since `KeyInterceptor` runs ahead of the field editor.
    private func updateModeHandler() {
        let active = scrollMode.isActive || search.isActive
        keyModeHost?.modeHandler =
            active
            ? { [weak self] event in
                guard let self else { return false }
                if self.search.isEditing { return false }
                if self.search.handle(event) { return true }
                return self.scrollMode.handle(event)
            } : nil
        if let previous = modeRenderTarget, previous !== activeController {
            previous.setFocusedSurfaceRendersFocused(true)
        }
        modeRenderTarget = active ? activeController : nil
        activeController?.setFocusedSurfaceRendersFocused(!active)
    }

    private weak var modeRenderTarget: TabController?

    // Does not present the window: ordering it in and taking key belong to the caller, so tests stay off screen.
    func mountAndStart() {
        bindFirstControllerIfNeeded()
        mount(.instant)
        activeController?.start()
        renderTabBar()
        window.contentView?.layoutSubtreeIfNeeded()
        titlePoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitlesFromCWD() }
        }
    }

    private func refreshTitlesFromCWD() {
        var changed = false
        for id in tabs.order {
            guard let c = controllers[id] else { continue }
            let t = c.title
            if titles[id] != t { titles[id] = t; changed = true }
        }
        if changed { renderTabBar() }

        if busyDots() != lastBusyDots { renderDock() }
    }

    private func busyDots() -> (Bool, Bool, Bool) {
        let overlay = activeController?.overlayState
        return (
            overlay?.bottomBusy ?? false, overlay?.rightBusy ?? false,
            floats.isBusy(ToolFloat.scratch.id)
        )
    }

    private var lastBusyDots = (false, false, false)

    deinit { titlePoll?.invalidate() }

    private func makeController(cwd: URL?, workspace ws: Workspace? = nil) -> TabController {
        let mainCommand = ws?.main.flatMap { $0 == "shell" ? nil : $0 }
        let c = TabController(
            initialCWD: cwd, initialCommand: mainCommand, env: ws?.env ?? [:],
            isToolFloatOpen: { [weak self] in self?.floats.isOpen ?? false })
        c.rightDrawerCommand = ws?.right
        c.bottomDrawerCommand = ws?.bottom
        return c
    }

    private func mintTabID() -> TabID { defer { nextTabID += 1 }; return TabID(nextTabID) }

    enum SlideEdge { case fromRight, fromLeft }

    enum MountTransition {
        case instant
        case slide(from: SlideEdge)
    }

    @discardableResult
    private func mount(_ transition: MountTransition, onLanded: (() -> Void)? = nil) -> Bool {
        guard let c = activeController, mountedCanvas !== c.view else {
            restoreFocusToActive()
            renderDock()
            return true
        }
        let outgoing = mountedCanvas
        pinCanvas(c.view)
        if let outgoing {
            container.addSubview(c.view, positioned: .above, relativeTo: outgoing)
        }
        mountedCanvas = c.view
        restoreFocusToActive()
        renderDock()

        switch transition {
        case .instant:
            outgoing?.removeFromSuperview()
            return true
        case .slide(let edge):
            container.layoutSubtreeIfNeeded()
            let dx = edge == .fromRight ? container.bounds.width : -container.bounds.width
            var isStillMounting = true
            var landedInline = false
            Motion.slideSwap(incoming: c.view, outgoing: outgoing, dx: dx) { [weak self] in
                self?.detachIfInactive(outgoing)
                if isStillMounting { landedInline = true } else { onLanded?() }
            }
            isStillMounting = false
            return landedInline
        }
    }

    private func detachIfInactive(_ canvas: NSView?) {
        guard let canvas, canvas !== mountedCanvas else { return }
        canvas.removeFromSuperview()
    }

    private func pinCanvas(_ canvas: NSView) {
        canvas.wantsLayer = true
        canvas.layer?.removeAllAnimations()
        canvas.layer?.transform = CATransform3DIdentity
        canvas.layer?.opacity = 1
        if canvas.superview === container {
            container.addSubview(canvas, positioned: .below, relativeTo: nil)
            return
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
        ])
    }

    private func closeFloatForTabChange() { floats.close() }

    private func restoreFocusToActive() {
        if floats.isOpen { floats.refocus() } else { activeController?.restoreUnifiedFocus() }
    }

    // Below `tabBar`, so the ⌘W guard toast fired over an open float stays visible.
    private func presentWindowFloat(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .below, relativeTo: tabBar)
        let gutter = ChromeMetrics.windowGutter
        let insets = (
            leading: overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: gutter),
            trailing: overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -gutter),
            top: overlay.topAnchor.constraint(
                equalTo: container.topAnchor, constant: ChromeMetrics.topInset),
            bottom: overlay.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -gutter)
        )
        floatGutter = insets
        NSLayoutConstraint.activate([insets.leading, insets.trailing, insets.top, insets.bottom])
    }

    // At the front, above the toasts: a card owns the keyboard, so a notice on top of it reads as broken.
    private func presentWindowModal(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        let gutter = ChromeMetrics.windowGutter
        let insets = (
            leading: overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: gutter),
            trailing: overlay.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -gutter),
            top: overlay.topAnchor.constraint(
                equalTo: container.topAnchor, constant: ChromeMetrics.topInset),
            bottom: overlay.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -gutter)
        )
        modalGutter = insets
        NSLayoutConstraint.activate([insets.leading, insets.trailing, insets.top, insets.bottom])
    }

    private func reapplyFloatLayout() {
        guard let floatGutter else { return }
        let gutter = ChromeMetrics.windowGutter
        floatGutter.leading.constant = gutter
        floatGutter.trailing.constant = -gutter
        floatGutter.top.constant = ChromeMetrics.topInset
        floatGutter.bottom.constant = -gutter
    }

    private func reapplyModalLayout() {
        guard let modalGutter else { return }
        let gutter = ChromeMetrics.windowGutter
        modalGutter.leading.constant = gutter
        modalGutter.trailing.constant = -gutter
        modalGutter.top.constant = ChromeMetrics.topInset
        modalGutter.bottom.constant = -gutter
    }

    private func newTab() {
        cancelConfirm()
        addTab(cwd: ShellLaunch.newSessionCWD(focused: activeController?.focusedCWD), pinnedTitle: nil)
    }

    private func addTab(cwd: URL?, pinnedTitle: String?, workspace: Workspace? = nil) {
        Log.info("tab opened", category: .tabs)
        closeModal()
        closeFloatForTabChange()
        let id = mintTabID()
        tabs.add(id)
        installController(
            id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace,
            transition: .slide(from: .fromRight))
    }

    private func replaceActiveTab(cwd: URL, pinnedTitle: String?, workspace: Workspace?) {
        closeFloatForTabChange()
        let id = tabs.activeID
        let old = controllers[id]
        if mountedCanvas === old?.view {
            old?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        old?.shutdown()
        floats.shutdownScope(id)
        installController(
            id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace, transition: .instant)
    }

    // The recipe waits for the canvas motion: a drawer sliding the same way as its canvas has no readable motion.
    private func installController(
        id: TabID, cwd: URL?, pinnedTitle: String?, workspace: Workspace?, transition: MountTransition
    ) {
        let c = makeController(cwd: cwd, workspace: workspace)
        c.pinnedTitle = pinnedTitle
        controllers[id] = c
        titles[id] = c.title
        wire(c, id: id)
        let landed = mount(transition) { [weak self, weak c] in
            guard let self, let c, let workspace, self.controllers[id] === c else { return }
            c.applyRecipe(workspace)
            if self.tabs.activeID != id { self.restoreFocusToActive() }
        }
        c.start()
        if landed, let workspace { c.applyRecipe(workspace) }
        renderTabBar()
    }

    private func select(_ id: TabID, slideFrom: SlideEdge? = nil) {
        closeModal()
        guard tabs.order.contains(id), id != tabs.activeID else { return }
        Log.info("tab switched", category: .tabs)
        closeFloatForTabChange()
        clearAttention(id)
        cancelConfirm()
        let oldIndex = tabs.order.firstIndex(of: tabs.activeID) ?? 0
        tabs.select(id)
        let newIndex = tabs.order.firstIndex(of: id) ?? 0
        mount(.slide(from: slideFrom ?? (newIndex > oldIndex ? .fromRight : .fromLeft)))
        renderTabBar()
    }

    private func cycleTab(_ delta: Int) {
        guard tabs.order.count > 1, let i = tabs.order.firstIndex(of: tabs.activeID) else { return }
        let n = tabs.order.count
        select(tabs.order[(i + delta + n) % n], slideFrom: delta > 0 ? .fromRight : .fromLeft)
    }

    private func moveActiveTab(_ delta: Int) {
        guard tabs.move(tabs.activeID, by: delta) else { return }
        Log.info("tab moved", category: .tabs)
        renderTabBar()
    }

    private func openRenameTab(_ id: TabID) {
        guard let controller = controllers[id] else { return }
        cancelConfirm()
        if modal?.kind == .renameTab { closeModal(); return }
        if modal != nil { closeModal() }
        let overlay = RenameTabOverlay(
            current: controller.title, liveTitle: controller.liveTitle,
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { [weak self] name in
                self?.renameTab(id, to: name)
                self?.closeModal()
            },
            onCancel: { [weak self] in self?.closeModal() })
        presentModal(overlay, kind: .renameTab)
    }

    private func renameTab(_ id: TabID, to name: String) {
        guard let controller = controllers[id] else { return }
        controller.pinnedTitle = name.isEmpty ? nil : name
        titles[id] = controller.title
        renderTabBar()
    }

    private func closeTab(_ id: TabID, dismissingModal: Bool = true) {
        Log.info("tab closed", category: .tabs)
        if dismissingModal { closeModal() }
        closeFloatForTabChange()
        cancelConfirm()
        let survived = tabs.close(id)
        let controller = controllers[id]
        if mountedCanvas === controller?.view {
            controller?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        controller?.shutdown()
        floats.shutdownScope(id)
        controllers[id] = nil
        titles[id] = nil
        clearAttention(id)
        if !survived { window.close(); return }
        clearAttention(tabs.activeID)
        mount(.instant)
        renderTabBar()
    }

    private func presentModal(_ overlay: ModalOverlay, kind: ModalKind) {
        guard activeController != nil else { return }
        endModes()
        floats.cancelPendingOpen()
        pendingModal = nil
        presentWindowModal(overlay)
        modal = (overlay, kind)
        overlay.focusInitialResponder()
        overlay.animateIn()
        renderDock()
    }

    private func closeModal() {
        pendingModal = nil
        guard let overlay = modal?.overlay else { return }
        modal = nil
        modalGutter = nil
        overlay.animateOut { overlay.removeFromSuperview() }
        restoreFocusToActive()
        renderDock()
    }

    // Built after the off-main read rather than presented empty, which would flash as it resized.
    private func toggleRepoPicker() {
        if modal?.kind == .repoPicker || pendingModal == .repoPicker { closeModal(); return }
        pendingModal = .repoPicker
        ConfigLoader.loadWorkspaces { [weak self] workspaces in
            guard let self, self.pendingModal == .repoPicker else { return }
            self.pendingModal = nil
            let picker = RepoPickerOverlay(
                entries: workspaces,
                background: Theme.current.chrome.background.nsColor,
                removals: self.worktreeRemovals,
                onChoose: { [weak self] ws, replace in self?.openWorkspace(ws, replaceCurrentTab: replace) },
                onAddWorkspace: { [weak self] in self?.openAddWorkspaceForm() },
                onDismiss: { [weak self] in self?.closeModal() }
            )
            self.presentModal(picker, kind: .repoPicker)
        }
    }

    private func toggleCommandPalette() {
        if modal?.kind == .commandPalette { closeModal(); return }
        let palette = CommandPaletteOverlay(
            commands: { [weak self] in
                CommandCatalog.commands(tabCount: self?.tabs.order.count ?? 0)
            },
            background: Theme.current.chrome.background.nsColor,
            onRun: { [weak self] chord in self?.runCommand(chord) },
            onDismiss: { [weak self] in self?.closeModal() }
        )
        presentModal(palette, kind: .commandPalette)
    }

    // Waits for the load so the collision check is right from the first keystroke.
    private func openAddWorkspaceForm() {
        closeModal()
        pendingModal = .workspaceForm
        ConfigLoader.loadWorkspaces { [weak self] workspaces in
            guard let self, self.pendingModal == .workspaceForm else { return }
            self.pendingModal = nil
            let form = AddWorkspaceOverlay(
                existingTitles: Set(workspaces.map(\.title)),
                background: Theme.current.chrome.background.nsColor,
                onSubmit: { [weak self] ws in self?.submitNewWorkspace(ws) },
                onCancel: { [weak self] in self?.closeModal() }
            )
            self.presentModal(form, kind: .workspaceForm)
        }
    }

    private func createWorktreeFromPicker() {
        guard let picker = modal?.overlay as? RepoPickerOverlay, let target = picker.createTarget
        else { return }
        closeModal()
        pendingModal = .worktreeForm
        GitRepoStatus.createOptions(in: target.repo) { [weak self] options in
            guard let self, self.pendingModal == .worktreeForm else { return }
            self.pendingModal = nil
            let form = NewWorktreeOverlay(
                workspace: target.workspace, options: options,
                background: Theme.current.chrome.background.nsColor,
                onSubmit: { [weak self] request in
                    self?.createWorktree(request, from: target)
                },
                onCancel: { [weak self] in self?.reopenRepoPicker() },
                onDismiss: { [weak self] in self?.closeModal() },
                onEditWorkspace: { [weak self] in
                    self?.openWorkspaceForm(
                        editing: target.workspace,
                        returningTo: { [weak self] in self?.reopenRepoPicker() })
                }
            )
            self.presentModal(form, kind: .worktreeForm)
        }
    }

    private func createWorktree(
        _ request: NewWorktreeOverlay.Request, from target: RepoPickerOverlay.CreateTarget
    ) {
        let workspace = target.workspace
        let card = modal?.overlay as? NewWorktreeOverlay
        card?.beginWork("Creating \(Self.branchName(of: request))")
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(Worktree, CarryReport), Error>
            do {
                let worktree: Worktree
                switch request {
                case .newBranch(let branch, let base):
                    worktree = try WorktreeStore.create(branch: branch, base: base, in: target.repo)
                case .existingBranch(let branch):
                    worktree = try WorktreeStore.create(existingBranch: branch, in: target.repo)
                }
                let report = WorktreeCarry.copy(
                    workspace.carry, from: workspace.path, into: worktree.path,
                    onEntry: { name in
                        DispatchQueue.main.async { [weak self, weak card] in
                            guard let card, self?.isPresenting(card) == true else { return }
                            card.setPhase("Copying \(name)")
                        }
                    })
                result = .success((worktree, report))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self, weak card] in
                guard let self else { return }
                let stillUp = card.map(self.isPresenting) ?? false
                switch result {
                case .success(let (worktree, report)):
                    if stillUp { self.closeModal() }
                    self.openWorkspace(
                        RepoPickerOverlay.workspace(for: worktree, parent: workspace),
                        replaceCurrentTab: false)
                    self.reportCarry(report)
                case .failure(let error):
                    if stillUp {
                        card?.failWork(error.localizedDescription)
                    } else {
                        self.toasts.show(
                            ToastContent(
                                variant: .warning, title: "Couldn't Create the Worktree",
                                message: error.localizedDescription))
                    }
                }
            }
        }
    }

    static func branchName(of request: NewWorktreeOverlay.Request) -> String {
        switch request {
        case .newBranch(let branch, _): return branch
        case .existingBranch(let branch): return branch
        }
    }

    private func isPresenting(_ card: NewWorktreeOverlay) -> Bool {
        (modal?.overlay as? NewWorktreeOverlay) === card
    }

    #if DEBUG
        func isPresentingForTesting(_ card: NewWorktreeOverlay) -> Bool { isPresenting(card) }
    #endif

    // `.notThere` stays silent: one section covers a repo before and after its first install.
    private func reportCarry(_ report: CarryReport) {
        let lost = report.skipped.filter { $0.reason != .notThere }
        guard !lost.isEmpty else { return }
        let list = lost.map { "\($0.name) \($0.reason.explanation)" }.joined(separator: ", ")
        toasts.show(
            ToastContent(variant: .warning, title: "Couldn't Copy Everything", message: "\(list)."))
    }

    private func removeSelectedWorktreeInPicker() {
        guard let picker = modal?.overlay as? RepoPickerOverlay,
            let selection = picker.selectedWorktree
        else { return }
        let (worktree, parent) = selection
        let openTabs = onCountTabsAtPath?(worktree.path) ?? tabCount(atPath: worktree.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let carried = parent.carry.compactMap { entry -> String? in
                let url = worktree.path.appendingPathComponent(entry)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return PathDisplay.isDirectory(url) ? entry + "/" : entry
            }
            let items = WorktreeRemovalMessage.items(
                for: worktree, state: WorktreeStore.state(worktree), carried: carried, openTabs: openTabs)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.modal?.overlay === picker,
                    !self.worktreeRemovals.isRemoving(worktree.path)
                else { return }
                self.confirmRemoveWorktree(picker, worktree, from: parent, items: items)
            }
        }
    }

    // A card, not the toast confirm, because this deletes a folder and cannot be undone.
    private func confirmRemoveWorktree(
        _ picker: RepoPickerOverlay, _ worktree: Worktree, from parent: Workspace,
        items: [ConfirmCardChecklist.Item]
    ) {
        let name = WorktreeRemovalMessage.name(worktree)
        let card = ConfirmCard(
            title: "Remove Worktree", items: items, confirmLabel: "Remove",
            background: Theme.current.chrome.background.nsColor,
            onCancel: { [weak picker] in picker?.dismissConfirm() },
            onConfirm: { [weak self, weak picker] in
                picker?.dismissConfirm()
                self?.beginWorktreeRemoval(worktree, from: parent, named: name)
            })
        picker.presentConfirm(card)
    }

    private func beginWorktreeRemoval(_ worktree: Worktree, from parent: Workspace, named name: String) {
        worktreeRemovals.remove(worktree, in: parent.path) { [weak self] error in
            guard let self, let error else { return }
            self.toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Remove \(name)",
                    message: error.localizedDescription))
        }
    }

    // Checks the confirm itself because the Help menu bypasses `handle`'s `isConfirmOpen` gate.
    func openReportIssue() {
        if isConfirmOpen { return }
        if modal?.kind == .reportIssue { closeModal(); return }
        if modal != nil { closeModal() }
        let overlay = ReportIssueOverlay(
            report: .current(),
            background: Theme.current.chrome.background.nsColor,
            onOpenURL: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.closeModal()
            },
            onExportDiagnostics: { [weak self] in self?.exportDiagnostics() },
            onCancel: { [weak self] in self?.closeModal() })
        presentModal(overlay, kind: .reportIssue)
    }

    private enum SettingsLanding { case top, tools, workspaces, terminal, appearance, general, shortcuts }

    private static func landing(for scope: ConfigDiagnostic.Scope) -> SettingsLanding {
        switch scope {
        case .keybind, .keybindLine: return .shortcuts
        case .toolFloat, .toolFloatField: return .tools
        case .setting(let key): return landing(forSettingKey: key)
        }
    }

    // Mirrors the keys each `SettingsFormSection` registers in `populate()`.
    private static func landing(forSettingKey key: String) -> SettingsLanding {
        switch key {
        case "font-family", "font-size", "font-thicken", "cursor-style", "cursor-style-blink",
            "cursor-thickness", "cursor-shader", "background-alpha", "macos-option-as-alt",
            "scroll-multiplier", "shell", "shell-args", "tab-inherit-cwd", "editor", "ai":
            return .terminal
        case "theme", "accent-color", "window-chrome", "backdrop-alpha", "window-gutter", "pane-gap",
            "bottom-drawer-fraction", "right-drawer-fraction", "drawer-resize-step", "max-drawer-fraction",
            "reduce-motion", "hide-toolbar-buttons":
            return .appearance
        case "agent-notifications", "attention-toast", "completion-toast", "toast-duration",
            "automatic-update-checks":
            return .general
        default:
            return .top
        }
    }

    private static func navTitle(for landing: SettingsLanding) -> String? {
        switch landing {
        case .top: return nil
        case .tools: return "Tools"
        case .workspaces: return "Workspaces"
        case .terminal: return "Terminal"
        case .appearance: return "Appearance"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        }
    }

    #if DEBUG
        static func settingsLandingNavTitleForTesting(for scope: ConfigDiagnostic.Scope) -> String? {
            navTitle(for: landing(for: scope))
        }
    #endif

    private func openSettings(landing: SettingsLanding = .top) {
        if modal?.kind == .settings { closeModal(); return }
        let toolsSection = SettingsToolsSection()
        toolsSection.onEditFloat = { [weak self] float in self?.openToolFloatForm(editing: float) }
        toolsSection.onReorder = { [weak self] floats in self?.reorderToolFloats(floats) }
        let workspacesSection = SettingsWorkspacesSection()
        workspacesSection.onEditWorkspace = { [weak self] ws in self?.openWorkspaceForm(editing: ws) }
        workspacesSection.onReorder = { [weak self] moved, neighbour in
            self?.reorderWorkspaces(moved, with: neighbour) ?? false
        }
        let sections: [SettingsSection] = [
            SettingsAppearanceSection(),
            SettingsGeneralSection(),
            SettingsTerminalSection(),
            SettingsKeybindsSection(capturer: keybindCapturer),
            toolsSection,
            workspacesSection,
        ].sorted { $0.navTitle.localizedCaseInsensitiveCompare($1.navTitle) == .orderedAscending }
        let overlay = SettingsOverlay(
            sections: sections,
            capturer: keybindCapturer,
            initialSection: Self.navTitle(for: landing).flatMap { title in
                sections.firstIndex { $0.navTitle == title }
            } ?? 0,
            background: Theme.current.chrome.background.nsColor,
            onClose: { [weak self] in self?.closeModal() }
        )
        overlay.onReportIssue = { [weak self] in self?.openReportIssue() }
        presentModal(overlay, kind: .settings)
    }

    // Always opens, never toggles: someone acting on the toast wants the section.
    func openSettings(for scope: ConfigDiagnostic.Scope) {
        if modal != nil { closeModal() }
        openSettings(landing: Self.landing(for: scope))
    }

    func showConfigDiagnosticsToast(_ content: ToastContent, landingScope: ConfigDiagnostic.Scope) {
        weak var toast: ToastView?
        let actions = [
            ToastAction(title: "Dismiss", kind: .cancel) { [weak self] in
                toast.map { self?.toasts.dismiss($0) }
            },
            ToastAction(title: "Open Settings", kind: .primary) { [weak self] in
                toast.map { self?.toasts.dismiss($0) }
                self?.openSettings(for: landingScope)
            },
        ]
        let shown = toasts.showSticky(content, actions: actions)
        shown.onClose = { [weak self, weak shown] in shown.map { self?.toasts.dismiss($0) } }
        toast = shown
        configDiagnosticsToast = shown
    }

    private weak var configDiagnosticsToast: ToastView?

    // Swift has no weak array element.
    private struct WeakToast {
        weak var value: ToastView?
    }

    private var conflictToasts: [(conflict: KeybindConflict, toast: WeakToast)] = []

    // Reconciles rather than rebuilds, so a card the user did not touch does not spring out and back.
    func showConflictToasts(_ conflicts: [KeybindConflict]) {
        var kept: [(conflict: KeybindConflict, toast: WeakToast)] = []
        for entry in conflictToasts {
            guard let toast = entry.toast.value else { continue }
            if conflicts.contains(entry.conflict) {
                kept.append(entry)
            } else {
                toasts.dismiss(toast)
            }
        }
        conflictToasts = kept
        for conflict in conflicts where !kept.contains(where: { $0.conflict == conflict }) {
            weak var toast: ToastView?
            let answer = { [weak self] (resolve: (KeybindConflict) -> Bool) in
                guard resolve(conflict) else { return }
                toast.map { self?.toasts.dismiss($0) }
            }
            var actions: [ToastAction] = []
            if conflict.isRevertable {
                actions.append(
                    ToastAction(title: "Revert", kind: .cancel) { answer(KeybindConflictResolver.revert) })
            }
            if conflict.isAcceptable {
                actions.append(
                    ToastAction(title: "Accept", kind: .primary) { answer(KeybindConflictResolver.accept) })
            }
            let content = ToastContent(
                variant: .warning, title: conflict.headline, message: conflict.message)
            let shown = toasts.showSticky(content, actions: actions, showsClose: true)
            shown.onClose = { [weak self] in toast.map { self?.toasts.dismiss($0) } }
            toast = shown
            conflictToasts.append((conflict, WeakToast(value: shown)))
        }
    }

    func dismissConflictToasts() {
        conflictToasts.compactMap(\.toast.value).forEach { toasts.dismiss($0) }
        conflictToasts = []
    }

    static func deliverConflictNotices(
        _ conflicts: [KeybindConflict], to keyWindow: WindowController?,
        replacingAcross windows: [WindowController]
    ) -> Bool {
        guard let keyWindow else { return false }
        windows.filter { $0 !== keyWindow }.forEach { $0.dismissConflictToasts() }
        keyWindow.showConflictToasts(conflicts)
        return true
    }

    // Sweeps other windows only once the key window resolves, or an accurate notice comes down with nothing replacing it.
    static func deliverConfigDiagnosticsNotice(
        _ content: ToastContent, landingScope: ConfigDiagnostic.Scope,
        to keyWindow: WindowController?, replacingAcross windows: [WindowController]
    ) -> Bool {
        guard let keyWindow else { return false }
        windows.forEach { $0.dismissConfigDiagnosticsToast() }
        keyWindow.showConfigDiagnosticsToast(content, landingScope: landingScope)
        return true
    }

    // Reads `builtToasts` so retracting never constructs the presenter.
    func dismissConfigDiagnosticsToast() {
        guard let toast = configDiagnosticsToast else { return }
        configDiagnosticsToast = nil
        builtToasts?.dismiss(toast)
    }

    private enum ToolFormReturn { case settings, none }

    private func toolFormReturnForNewTool() -> ToolFormReturn {
        switch closingModalKind {
        case .settings: return .settings
        case .toolFloatForm: return toolFormReturn ?? .none
        default: return .none
        }
    }

    // `existingIDs` holds the built-ins because the parser refuses a line claiming one.
    private func openToolFloatForm(editing float: ToolFloat?, returnTo: ToolFormReturn = .settings) {
        closeModal()
        let existingIDs = Set(GeneralConfig.current.floats.map(\.id))
            .subtracting(float.map { [$0.id] } ?? [])
            .union(ToolFloat.builtInIDs)
        let originalID = float?.id
        let form = ToolFloatFormOverlay(
            editing: float,
            existingIDs: existingIDs,
            capturer: keybindCapturer,
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { [weak self] built in
                self?.submitToolFloat(built, replacing: originalID, returnTo: returnTo)
            },
            onCancel: { [weak self] in self?.finishToolFloatForm(returnTo) },
            onDelete: float.map { existing in { [weak self] in self?.deleteToolFloat(existing) } }
        )
        toolFormReturn = returnTo
        presentModal(form, kind: .toolFloatForm)
    }

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

    private func submitToolFloat(
        _ float: ToolFloat, replacing originalID: String?, returnTo: ToolFormReturn = .settings
    ) {
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
        finishToolFloatForm(returnTo)
    }

    private func finishToolFloatForm(_ returnTo: ToolFormReturn) {
        toolFormReturn = nil
        switch returnTo {
        case .settings: reopenSettingsOnTools()
        case .none: closeModal()
        }
    }

    // Leaves Settings open: rebuilding it would lose the user's place in the list mid-⌥↓.
    private func reorderToolFloats(_ floats: [ToolFloat]) {
        do {
            try ConfigWriter.applyFloatOrder(floats)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Reorder Tool Floats",
                    message: "Failed to update the config file: \(error.localizedDescription)"))
            return
        }
        AppConfig.reload()
    }

    private func reopenSettingsOnTools() {
        closeModal()
        openSettings(landing: .tools)
    }

    private func openWorkspaceForm(
        editing workspace: Workspace?, returningTo done: (() -> Void)? = nil
    ) {
        let done = done ?? { [weak self] in self?.reopenSettingsOnWorkspaces() }
        closeModal()
        pendingModal = .workspaceForm
        ConfigLoader.loadWorkspaces { [weak self] workspaces in
            guard let self, self.pendingModal == .workspaceForm else { return }
            self.pendingModal = nil
            let existingTitles = Set(workspaces.map(\.title))
                .subtracting(workspace.map { [$0.title] } ?? [])
            let originalTitle = workspace?.title
            let form = AddWorkspaceOverlay(
                editing: workspace,
                existingTitles: existingTitles,
                background: Theme.current.chrome.background.nsColor,
                onSubmit: { [weak self] built in
                    self?.submitWorkspace(built, replacing: originalTitle, then: done)
                },
                onCancel: done,
                onDelete: workspace.map { existing in
                    { [weak self] in self?.deleteWorkspace(existing, then: done) }
                }
            )
            self.presentModal(form, kind: .workspaceForm)
        }
    }

    private func submitWorkspace(
        _ ws: Workspace, replacing originalTitle: String?, then done: (() -> Void)? = nil
    ) {
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
        (done ?? reopenSettingsOnWorkspaces)()
    }

    private func deleteWorkspace(_ ws: Workspace, then done: (() -> Void)? = nil) {
        do {
            try WorkspacesWriter.remove(title: ws.title)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Delete Workspace",
                    message: "Failed to update the workspaces file: \(error.localizedDescription)"))
            return
        }
        (done ?? reopenSettingsOnWorkspaces)()
    }

    // Leaves Settings open: rebuilding it would lose the user's place in the list mid-⌥↓.
    private func reorderWorkspaces(_ moved: Workspace, with neighbour: Workspace) -> Bool {
        do {
            return try WorkspacesWriter.swap(moved.title, with: neighbour.title)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Reorder Workspaces",
                    message: "Failed to update the workspaces file: \(error.localizedDescription)"))
            return false
        }
    }

    private func reopenRepoPicker() {
        closeModal()
        toggleRepoPicker()
    }

    private func reopenSettingsOnWorkspaces() {
        closeModal()
        openSettings(landing: .workspaces)
    }

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

    private func runCommand(_ chord: KeyInterceptor.ReservedChord) {
        closeModal()
        handle(chord)
    }

    // Ends modes first, or a mode swallows the Return and Esc that answer the confirm.
    func presentConfirm(
        variant: ToastVariant, title: String, message: String,
        confirmLabel: String, onConfirm: @escaping () -> Void, onCancel: (() -> Void)? = nil
    ) {
        cancelConfirm()
        closeModal()
        endModes()
        confirmOnCancel = onCancel
        let content = ToastContent(variant: variant, title: title, message: message)
        let actions = [
            ToastAction(title: "Cancel", kind: .cancel) { [weak self] in self?.cancelConfirm() },
            ToastAction(title: confirmLabel, kind: .destructive) { [weak self] in
                guard self?.confirmToast != nil else { return }
                self?.tearDownConfirm()
                onConfirm()
            },
        ]
        let toast = toasts.confirm(content, actions: actions)
        confirmToast = toast
        window.makeFirstResponder(toast)
        renderDock()
    }

    private func cancelConfirm() {
        guard confirmToast != nil else { return }
        let onCancel = confirmOnCancel
        tearDownConfirm()
        onCancel?()
    }

    private func tearDownConfirm() {
        guard let toast = confirmToast else { return }
        confirmToast = nil
        confirmOnCancel = nil
        toasts.dismiss(toast)
        restoreFocusToActive()
        renderDock()
    }

    private func openWorkspace(_ ws: Workspace, replaceCurrentTab: Bool) {
        closeModal()
        guard replaceCurrentTab else {
            addTab(cwd: ws.path, pinnedTitle: ws.title, workspace: ws)
            return
        }
        let replace = { [weak self] in
            self?.replaceActiveTab(cwd: ws.path, pinnedTitle: ws.title, workspace: ws)
        }
        let tabIsBusy =
            activeController?.allSurfaces.contains(where: { $0.isBusy }) == true
            || floats.hasBusyInScope(tabs.activeID)
        guard tabIsBusy else {
            replace()
            return
        }
        presentConfirm(
            variant: .warning, title: "Replace Tab",
            message: "Replacing this tab will stop everything running in it.",
            confirmLabel: "Replace"
        ) { replace() }
    }

    func handle(_ chord: KeyInterceptor.ReservedChord) {
        guard !tabs.order.isEmpty else { return }
        closingModalKind = nil
        let active = activeController
        if isConfirmOpen { return }
        if let modal {
            if modal.overlay.isShowingOverlaidCard { return }
            if let selfToggle = modal.kind.selfToggle, chord == selfToggle {
                closeModal()
                return
            }
            if modal.kind == .repoPicker, chord == .createWorktree {
                createWorktreeFromPicker()
                return
            }
            if modal.kind == .repoPicker, chord == .removeWorktree {
                removeSelectedWorktreeInPicker()
                return
            }
            switch chord {
            case .toggleRepoPicker, .toggleCommandPalette, .openSettings, .toggleToolFloat, .reportIssue,
                .newTool:
                closingModalKind = modal.kind
                closeModal()
            default:
                return
            }
        }
        if floats.isOpen {
            switch chord {
            case .closePane:
                toasts.show(
                    ToastContent(
                        variant: .info, title: "Tool Float",
                        message: "Close \(activeFloatName ?? "the tool") first, then ⌘W."))
                return
            case .navLeft, .navRight, .navUp, .navDown, .prevPane, .nextPane,
                .splitVertical, .splitHorizontal,
                .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
                .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom:
                toastFloatBlocked()
                return
            case .toggleCommandPalette, .toggleRepoPicker, .openSettings, .reportIssue, .newTool,
                .renameTab:
                floats.close()
            case .toggleToolFloat, .newTab, .newWindow, .selectTab, .prevTab, .nextTab,
                .moveTabLeft, .moveTabRight, .fillScreen,
                .increaseFontSize, .decreaseFontSize, .resetFontSize, .selectAll,
                .toggleScrollMode, .toggleSearch, .searchSelection, .findNext, .findPrevious,
                .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown, .scrollToSelection,
                .jumpToPreviousPrompt, .jumpToNextPrompt, .pasteSelection, .clearScreen,
                .writeScreenFile, .copyScreenFilePath, .openScreenFile,
                .dismissToast, .dismissAllToasts:
                break
            default:
                return
            }
        }
        switch chord {
        case .splitVertical:
            Log.info("pane split (vertical)", category: .panes)
            active?.split(.vertical)
        case .splitHorizontal:
            Log.info("pane split (horizontal)", category: .panes)
            active?.split(.horizontal)
        case .prevPane: active?.cyclePane(-1)
        case .nextPane: active?.cyclePane(1)
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
        case .moveTabLeft: moveActiveTab(-1)
        case .moveTabRight: moveActiveTab(1)
        case .renameTab: openRenameTab(tabs.activeID)
        case .closePane:
            Log.info("close pane", category: .panes)
            requestClosePane()
        case .newWindow, .reloadConfig, .checkForUpdates,
            .increaseFontSize, .decreaseFontSize, .resetFontSize:
            onAppGlobalCommand?(chord)
        case .toggleBottomDrawer:
            Log.info("bottom drawer toggled", category: .drawers)
            active?.toggleBottomDrawer()
        case .toggleRightDrawer:
            Log.info("right drawer toggled", category: .drawers)
            active?.toggleRightDrawer()
        case .toggleZoom:
            Log.info("zoom toggled", category: .panes)
            search.end()
            active?.toggleZoom()
            updateModeHandler()
        case .dismissToast: builtToasts?.dismissOldest()
        case .dismissAllToasts: builtToasts?.dismissAll()
        case .toggleScrollMode: toggleScrollMode()
        case .toggleSearch: toggleSearch()
        case .searchSelection: searchSelection()
        case .findNext: search.navigate(.next)
        case .findPrevious: search.navigate(.previous)
        case .scrollToTop: scrollFocusedPane(.top)
        case .scrollToBottom: scrollFocusedPane(.bottom)
        case .scrollPageUp: scrollFocusedPane(.pageFraction(-1))
        case .scrollPageDown: scrollFocusedPane(.pageFraction(1))
        case .scrollToSelection: scrollFocusedPane(.selection)
        case .jumpToPreviousPrompt: scrollFocusedPane(.prompt(-1))
        case .jumpToNextPrompt: scrollFocusedPane(.prompt(1))
        case .clearScreen: modeTarget?.surface.clearScreen()
        case .selectAll: selectAll(nil)
        case .writeScreenFile: modeTarget?.surface.writeScreenToFile(.paste)
        case .copyScreenFilePath: modeTarget?.surface.writeScreenToFile(.copy)
        case .openScreenFile: modeTarget?.surface.writeScreenToFile(.open)
        case .pasteSelection: pasteSelection()
        case .fillScreen: toggleFillScreen()
        case .toggleToolFloat(let id):
            pendingModal = nil
            if let spec = ToolFloatCatalog.byID(id) { floats.toggle(spec) }
        case .toggleRepoPicker: toggleRepoPicker()
        case .createWorktree, .removeWorktree: break
        case .toggleCommandPalette: toggleCommandPalette()
        case .openSettings: openSettings()
        case .reportIssue: openReportIssue()
        case .newTool: openToolFloatForm(editing: nil, returnTo: toolFormReturnForNewTool())
        }
    }

    private var preFillFrame: NSRect?

    private func toggleFillScreen() {
        let animate = !Motion.isReduceMotionEnabled()
        if let restore = preFillFrame {
            preFillFrame = nil
            window.setFrame(restore, display: true, animate: animate)
            return
        }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        preFillFrame = window.frame
        window.setFrame(visible, display: true, animate: animate)
    }

    var tabCount: Int { tabs.order.count }

    func selectTab(_ id: TabID) { select(id) }

    func clearActiveTabNotification() {
        guard !tabs.order.isEmpty else { return }
        AgentNotifier.shared.clear(windowID: windowID, tabID: tabs.activeID)
    }

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

    private func requestClosePane() {
        guard let active = activeController else { return }

        if active.isDrawerFocused {
            guard active.focusedDrawerIsBusy else { active.closeFocusedDrawer(); return }
            presentConfirm(
                variant: .warning, title: "Close Drawer",
                message: "Closing this drawer will stop the process running in it.",
                confirmLabel: "Close"
            ) { [weak self] in self?.activeController?.closeFocusedDrawer() }
            return
        }

        let lastPane = active.isSinglePane
        let busy = active.focusedPaneIsBusy
        let closesWindow = lastPane && tabs.order.count == 1

        let needsConfirm =
            busy
            || (lastPane && (active.hasBusyDrawer || floats.hasBusyInScope(tabs.activeID)))
            || (closesWindow && floats.hasBusy)
        guard needsConfirm else {
            if active.closeFocused() == false { closeTab(tabs.activeID) }
            return
        }

        let title = lastPane ? "Close Tab" : "Close Pane"
        let message =
            lastPane
            ? "Closing this tab will stop everything running in it."
            : "Closing this pane will stop the process running in it."
        presentConfirm(
            variant: .warning, title: title, message: message, confirmLabel: "Close"
        ) { [weak self] in
            guard let self, let active = self.activeController else { return }
            if active.closeFocused() == false { self.closeTab(self.tabs.activeID) }
        }
    }

    // Terminal end of the responder chain for Copy, Paste and Select All; an open card swallows them.
    @objc func copy(_ sender: Any?) {
        if isConfirmOpen || isModalOverlayOpen { return }
        if floats.isOpen { floats.copyFromSurface(sender) } else { activeController?.copyFromSurface(sender) }
    }
    @objc func paste(_ sender: Any?) {
        if isConfirmOpen || isModalOverlayOpen { return }
        if floats.isOpen { floats.pasteToSurface(sender) } else { activeController?.pasteToSurface(sender) }
    }
    @objc func selectAll(_ sender: Any?) {
        if isConfirmOpen || isModalOverlayOpen { return }
        if floats.isOpen {
            floats.selectAllInSurface(sender)
        } else {
            activeController?.focusedScrollTarget?.surface.selectAll()
        }
    }

    private func wire(_ c: TabController, id: TabID) {
        c.onTitleChanged = { [weak self] in
            guard let self, let c = self.controllers[id] else { return }
            self.titles[id] = c.title
            self.renderTabBar()
        }
        c.onLastPaneClosed = { [weak self] in self?.closeTab(id) }
        c.onOverlayStateChanged = { [weak self] in self?.renderDock() }
        c.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        c.onPaneStartFailed = { [weak self] retry, close in
            self?.presentSurfaceFailureToast(retry: retry, close: close)
        }
        c.onFocusChanged = { [weak self] in
            self?.cancelConfirm()
            self?.endModes()
        }
        c.onSurfaceEvent = { [weak self] surface, event in self?.report(surface, event) }
        c.onNotification = { [weak self] n in self?.agentNotified(id: id, notification: n) }
        c.onCommandFinished = { [weak self] result in self?.commandFinished(id: id, result: result) }
    }

    // The banner lands on `owner`: a hidden Scratch asking for input is usually not in the active tab.
    private func floatNotified(
        _ notification: TerminalNotification, from spec: ToolFloat, owner: TabID?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tabs.order.isEmpty,
                AgentNotifier.shouldPushNotification(
                    appActive: NSApp.isActive, enabled: GeneralConfig.current.agentNotifications)
            else { return }
            let target = owner.flatMap { self.tabs.order.contains($0) ? $0 : nil } ?? self.tabs.activeID
            AgentNotifier.shared.notify(
                windowID: self.windowID, tabID: target, title: spec.title,
                body: notification.body.isEmpty ? notification.title : notification.body)
        }
    }

    private func agentNotified(id: TabID, notification: TerminalNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabs.order.contains(id) else { return }
            let message = notification.body.isEmpty ? notification.title : notification.body

            if AgentNotifier.shouldPushNotification(
                appActive: NSApp.isActive, enabled: GeneralConfig.current.agentNotifications)
            {
                AgentNotifier.shared.notify(
                    windowID: self.windowID, tabID: id, title: self.titles[id] ?? "shell", body: message)
            }

            guard id != self.tabs.activeID else { return }
            let wasWaiting = self.attentionStates[id] == .waiting
            self.presentWaitingToast(for: id, message: message)
            if !wasWaiting { self.renderTabBar() }
        }
    }

    private func commandFinished(id: TabID, result: TerminalCommandResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabs.order.contains(id), id != self.tabs.activeID,
                result.duration >= Self.commandCompletionThreshold,
                self.attentionStates[id] != .waiting
            else { return }

            self.presentCompletedToast(for: id, result: result)
            self.renderTabBar()
        }
    }

    private func presentCompletedToast(for id: TabID, result: TerminalCommandResult) {
        if let old = attentionToasts[id] { toasts.dismiss(old) }
        let content = ToastContent(
            variant: result.exitCode.map { $0 == 0 ? .positive : .warning } ?? .positive,
            title: titles[id] ?? "shell", message: Self.commandResultMessage(result))
        let actions = [
            ToastAction(title: "Dismiss", kind: .cancel) { [weak self] in
                guard let self else { return }
                self.clearAttention(id)
                self.renderTabBar()
            },
            ToastAction(
                title: "Switch", kind: .primary,
                shortcut: { [weak self] in self?.selectTabShortcut(for: id) ?? "" }
            ) { [weak self] in self?.select(id) },
        ]
        attentionStates[id] = .completed
        attentionToasts[id] = mountAttentionToast(
            for: id, content: content, actions: actions,
            autoDismiss: GeneralConfig.current.completionToast == .auto)
    }

    static func commandResultMessage(_ result: TerminalCommandResult) -> String {
        let elapsed = elapsedDescription(result.duration)
        guard let code = result.exitCode, code != 0 else { return "Finished in \(elapsed)." }
        return "Exited \(code) after \(elapsed)."
    }

    private static func elapsedDescription(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
        if minutes > 0 { return "\(minutes)m \(remainder)s" }
        return "\(remainder)s"
    }

    private func presentWaitingToast(for id: TabID, message: String) {
        if let old = attentionToasts[id] { toasts.dismiss(old) }
        let content = ToastContent(
            variant: .info, title: titles[id] ?? "shell", message: message, icon: "bell.fill")
        let actions = [
            ToastAction(title: "Dismiss", kind: .cancel) { [weak self] in
                guard let self else { return }
                self.clearAttention(id)
                self.renderTabBar()
            },
            ToastAction(
                title: "Switch", kind: .primary,
                shortcut: { [weak self] in self?.selectTabShortcut(for: id) ?? "" }
            ) { [weak self] in self?.select(id) },
        ]
        attentionStates[id] = .waiting
        attentionToasts[id] = mountAttentionToast(
            for: id, content: content, actions: actions,
            autoDismiss: GeneralConfig.current.attentionToast == .auto)
    }

    private func mountAttentionToast(
        for id: TabID, content: ToastContent, actions: [ToastAction], autoDismiss: Bool
    ) -> ToastView {
        let toast = toasts.showSticky(content, actions: actions, autoDismiss: autoDismiss)
        toast.onClose = { [weak self] in
            guard let self else { return }
            self.clearAttention(id)
            self.renderTabBar()
        }
        toast.onDismissed = { [weak self, weak toast] in
            guard let self, let toast, self.attentionToasts[id] === toast else { return }
            self.attentionToasts[id] = nil
        }
        return toast
    }

    private func presentSurfaceFailureToast(retry: @escaping () -> Void, close: @escaping () -> Void) {
        let content = ToastContent(
            variant: .warning, title: "Terminal Didn't Start",
            message: "The terminal surface failed to launch.")
        weak var toast: ToastView?
        let actions = [
            ToastAction(title: "Close Pane", kind: .destructive) { [weak self] in
                toast.map { self?.toasts.dismiss($0) }
                close()
            },
            ToastAction(title: "Retry", kind: .primary) { [weak self] in
                toast.map { self?.toasts.dismiss($0) }
                retry()
            },
        ]
        toast = toasts.showSticky(content, actions: actions)
    }

    func openWorkspaceForTesting(_ ws: Workspace, replaceCurrentTab: Bool) {
        openWorkspace(ws, replaceCurrentTab: replaceCurrentTab)
    }

    var focusedPanelForTesting: PanelHostView? { activeController?.focusedScrollTarget?.panel }
    var focusedScrollTargetForTesting: (surface: TerminalSurface, panel: PanelHostView)? {
        activeController?.focusedScrollTarget
    }
    var focusedSurfaceForTesting: TerminalSurface? { activeController?.focusedScrollTarget?.surface }

    // Not the focused scroll target, which is nil whenever something other than a pane holds focus.
    var anyTerminalSurface: TerminalSurface? { activeController?.allSurfaces.first }

    func presentSurfaceFailureToastForTesting(retry: @escaping () -> Void, close: @escaping () -> Void) {
        presentSurfaceFailureToast(retry: retry, close: close)
    }

    func notifyAgentForTesting(tabIndex: Int, message: String) {
        guard tabs.order.indices.contains(tabIndex) else { return }
        agentNotified(
            id: tabs.order[tabIndex], notification: TerminalNotification(title: "claude", body: message))
    }

    func waitingToastForTesting(tabIndex: Int) -> ToastView? {
        guard tabs.order.indices.contains(tabIndex) else { return nil }
        return attentionToasts[tabs.order[tabIndex]]
    }

    func notifyCommandFinishedForTesting(tabIndex: Int, result: TerminalCommandResult) {
        guard tabs.order.indices.contains(tabIndex) else { return }
        commandFinished(id: tabs.order[tabIndex], result: result)
    }

    func attentionStateForTesting(tabIndex: Int) -> TabAttentionState? {
        guard tabs.order.indices.contains(tabIndex) else { return nil }
        return attentionStates[tabs.order[tabIndex]]
    }

    func newTabForTesting() { handle(.newTab) }
    func closeTabForTesting(index: Int) {
        guard tabs.order.indices.contains(index) else { return }
        closeTab(tabs.order[index])
    }

    func selectTabForTesting(index: Int) {
        guard tabs.order.indices.contains(index) else { return }
        select(tabs.order[index])
    }

    func renameTabForTesting(index: Int) {
        guard tabs.order.indices.contains(index) else { return }
        openRenameTab(tabs.order[index])
    }

    var floatsForTesting: ToolFloatController { floats }

    var tabOrderForTesting: [TabID] { tabs.order }
    var tabTitlesForTesting: [String] { tabs.order.map { titles[$0] ?? "shell" } }

    var activeTabIDForTesting: TabID? { tabs.order.isEmpty ? nil : tabs.activeID }

    var hasBuiltToastsForTesting: Bool { builtToasts != nil }

    var backdropTintColorForTesting: NSColor? {
        tint.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }

    private func clearAttention(_ id: TabID) {
        attentionStates[id] = nil
        if let toast = attentionToasts.removeValue(forKey: id) { toasts.dismiss(toast) }
        AgentNotifier.shared.clear(windowID: windowID, tabID: id)
    }

    private func renderTabBar() {
        let items = tabs.order.enumerated().map { i, id in
            TabBarItem(
                id: id, index: i + 1,
                title: titles[id] ?? "shell",
                isActive: id == tabs.activeID,
                attentionState: attentionStates[id] ?? .idle)
        }
        tabBar.render(items)
        attentionToasts.values.forEach { $0.refreshShortcuts() }
    }

    private func selectTabShortcut(for id: TabID) -> String {
        guard let index = tabs.order.firstIndex(of: id).map({ $0 + 1 }), index <= 9 else { return "" }
        return CommandCatalog.spec(for: .selectTab(index)).shortcut
    }

    private func renderDock() {
        let overlay = activeController?.overlayState ?? OverlayState()
        dock.render(
            overlay: overlay, floatID: floats.activeID, paletteOpen: modal?.kind == .commandPalette,
            tab: tabs.order.isEmpty ? nil : tabs.activeID,
            isLiveInBackground: floats.isLiveInBackground, isFloatBusy: floats.isBusy)
        lastBusyDots = busyDots()
    }

    private func bindFirstControllerIfNeeded() {
        let firstID = tabs.order[0]
        if let c = controllers[firstID] { wire(c, id: firstID) }
    }

    // Ends capture and modes unconditionally: both handlers are app-wide and would strand every other window.
    private func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        pendingModal = nil
        cancelConfirm()
        keybindCapturer?.endCapture()
        endModes()
        titlePoll?.invalidate()
        titlePoll = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        floats.shutdown()
        for c in controllers.values { c.shutdown() }
        controllers.removeAll()
        onClosed?()
    }
}

extension WindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { tearDown() }

    func windowDidResignKey(_ notification: Notification) { endModes() }

    // Quit never fires `windowWillClose`, so without this every shell is orphaned.
    func tearDownForQuit() { tearDown() }
}
