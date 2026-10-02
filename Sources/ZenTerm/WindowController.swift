import AppKit
import AppLog
import PaneKit
import TabKit
import TerminalKit
import UniformTypeIdentifiers

@MainActor
final class WindowController: NSObject {
    let window: HostWindow

    private var workspaces: [WorkspaceController]
    private var selection: WindowSelection
    private var nextWorkspaceID = 2
    private var attentionCards: [TabID: ToastView] = [:]
    // A card is keyed by the tab it sits on but answers one surface, which may be a drawer or a float.
    private var cardSurfaces: [TabID: SurfaceID] = [:]
    private var cardTitles: [TabID: () -> String] = [:]
    private let attention = AttentionStore()
    private let agents = AgentRoster()
    private let agentStates = AgentStateTracker()
    private static let commandCompletionThreshold: TimeInterval = 10
    private var nextTabID = 1

    // `TabID`s are unique only within a window, so notification identity pairs this with the tab id.
    let windowID: Int
    private static var nextWindowID = 1

    private static var backdropTintAlpha: CGFloat { GeneralConfig.current.backdropAlpha }

    private let container = NSView()
    private let canvasHost = NSView()
    private let tint = NSView()
    // Built on first use so the stack mounts above the canvas; not `lazy`, so re-insetting can't construct one.
    private var builtToasts: ToastPresenter?
    private var toasts: ToastPresenter {
        if let builtToasts { return builtToasts }
        let presenter = ToastPresenter(
            host: container, below: modal?.overlay, topInset: Self.toastTopInset,
            trailingInset: Self.toastTrailingInset, dismissAfter: GeneralConfig.current.toastDuration,
            isPresent: { [weak self] in self.map { Self.isPresent($0.window) } ?? true })
        builtToasts = presenter
        return presenter
    }

    private static var toastTopInset: CGFloat { ChromeMetrics.topInset + 12 }
    private static var toastTrailingInset: CGFloat { ChromeMetrics.windowGutter + 12 }

    func showToast(_ content: ToastContent) { toasts.show(content) }

    private var fontSizeCard: FontSizeCard?
    private var fontSizeDismissal: DispatchWorkItem?
    // The poll can see an agent exit before its result arrives, and only the result can tell a crash.
    private var exitsAwaitingResult: Set<SurfaceID> = []
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
        workspaces.flatMap(\.allSurfaces) + floats.allSurfaces
    }

    // Every surface, not only visible ones: a surface that took a press is owed its release wherever it went.
    func modifiersDidChange(_ event: NSEvent) {
        for surface in allTerminalSurfaces { surface.modifiersDidChange(event) }
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
            sessionCWD: { [weak self] in self?.activeController?.sessionCWD },
            yieldFocus: { [weak self] in
                self?.endModes()
                self?.activeController?.yieldFocusToFloat()
            },
            restoreFocus: { [weak self] in self?.activeController?.restoreUnifiedFocus() },
            currentTabID: { [weak self] in self?.activeWorkspace?.activeID })
        controller.onStateChanged = { [weak self] in self?.renderDock() }
        controller.onFocusChanged = { [weak self] in self?.syncWindowFocus() }
        controller.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        controller.onProgress = { [weak self] surface, progress in
            self?.progressChanged(surface: surface, progress: progress)
        }
        controller.onTitle = { [weak self] surface, title in
            self?.titleChanged(surface: surface, title: title)
        }
        controller.onSurfaceRegistered = { [weak self] surface, tab in
            self?.attention.register(surface, tab: tab)
        }
        controller.onSurfaceReleased = { [weak self] surface in
            self?.attention.release(surface)
            self?.agents.drop(surface)
            self?.agentStates.drop(surface)
            self?.renderAgents()
        }
        controller.onProgramLaunched = { [weak self] surface, command in
            self?.programLaunched(surface, command)
        }
        controller.onShown = { [weak self] surface in self?.surfaceShown(surface) }
        controller.onNotification = { [weak self] surface, n, spec, owner in
            self?.floatNotified(surface: surface, n, from: spec, owner: owner)
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
    private let sidebar: SidebarController
    private var mountedCanvas: NSView?
    private var connectView: HostConnectView?
    private var focusReturn: SidebarFocusStop?
    private var windowIsKey = true
    private var activeCanvasSlides = 0
    private let horizontalSlideFade = EdgeFade(axis: .horizontal)
    private let verticalSlideFade = EdgeFade(axis: .vertical)
    static let slideFadeDepth: CGFloat = 8

    private enum ModalKind {
        case repoPicker, commandPalette, workspaceForm, settings, toolFloatForm, reportIssue
        case renameTab, worktreeForm, sshHostForm

        var selfToggle: KeyInterceptor.ReservedChord? {
            switch self {
            case .repoPicker: return .toggleRepoPicker
            case .commandPalette: return .toggleCommandPalette
            case .settings: return .openSettings
            case .workspaceForm, .toolFloatForm, .reportIssue, .renameTab, .worktreeForm, .sshHostForm:
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

    var onClosedByRemovalAtPath: ((URL) -> ClosedByRemoval)?

    var isWorkspaceOpenInAnotherWindow: ((URL) -> Bool)?

    var revealWorkspaceInAnotherWindow: ((URL) -> Bool)?

    var revealHostInAnotherWindow: ((SSHHostID) -> Bool)?

    var openWorkspacesElsewhere: (() -> [RunningWorkspace])?

    var onWorktreeMarkChanged: (() -> Void)?

    var revealWorkspaceElsewhere: ((Int, WorkspaceID) -> Bool)?

    var worktreeRemovals = WorktreeRemovalTracker()

    func tabCount(atPath path: URL) -> Int {
        allTabIDs.filter { isClosedByRemoval($0, atPath: path) }.count
    }

    func closedByRemoval(atPath path: URL) -> ClosedByRemoval {
        var closed = ClosedByRemoval()
        var emptied = 0
        for workspace in workspaces {
            let inside = workspace.tabIDs.filter { isClosedByRemoval($0, atPath: path) }.count
            guard inside > 0 else { continue }
            if inside == workspace.tabIDs.count {
                closed.workspaces.append(workspace.name)
                emptied += 1
            } else {
                closed.tabs += inside
            }
        }
        return emptied == workspaces.count ? ClosedByRemoval(thisWindow: true) : closed
    }

    private func isClosedByRemoval(_ id: TabID, atPath path: URL) -> Bool {
        GitRepo.isInside(controller(id)?.openedCWD, path) || GitRepo.isInside(workspace(of: id)?.origin?.path, path)
    }

    // An open card keeps the keyboard: the picker is where the user watches the removal.
    func closeTabs(atPath path: URL) {
        let card = modal?.overlay
        for id in allTabIDs where isClosedByRemoval(id, atPath: path) {
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
        case .removed(let path): picker.dropWorktree(at: path, open: runningWorkspaces()); picker.relistWorktrees()
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
    private var hostStatusObserver: NSObjectProtocol?
    private var attentionObserver: NSObjectProtocol?
    /// Raises the window holding the agent that has waited longest and lands on it. False when it has gone.
    var revealWaitingAgentElsewhere: ((Int) -> Bool)?

    var onClosed: (() -> Void)?

    private var didTearDown = false

    var sessionCWD: URL? { activeController?.sessionCWD }
    var focusedPaneIsVim: Bool { !sidebar.hasFocus && activeController?.focusedPaneIsVim == true }

    var isToolFloatOpen: Bool { floats.isOpen }

    var isRepoPickerOpen: Bool { modal?.kind == .repoPicker }

    func modalOwns(_ chord: Chord) -> Bool { modal?.overlay.owns(chord) == true }

    func passesThrough(
        _ chord: Chord, as action: KeyInterceptor.ReservedChord, firstResponder: NSResponder?
    ) -> Bool {
        if TextEditingChords.owns(chord, firstResponder: firstResponder) { return true }
        if modalOwns(chord) { return true }
        if PickerChordGuard.shouldPassThrough(
            action: action, repoPickerIsOpen: isRepoPickerOpen, sidebarHasFocus: isSidebarFocused)
        {
            return true
        }
        return NavGuard.shouldPassThrough(
            chord: chord, action: action, focusedPaneIsVim: focusedPaneIsVim, toolFloatIsOpen: isToolFloatOpen)
    }

    var isSidebarFocused: Bool { sidebar.hasFocus }

    private var activeFloatName: String? {
        floats.activeID.flatMap(ToolFloatCatalog.byID)
            .map { $0.title.replacingOccurrences(of: "Open ", with: "") }
    }

    private var floatBlockToasts = ToastThrottle<Bool>()

    private func toastFloatBlocked() {
        guard floatBlockToasts.allows() else { return }
        toasts.show(
            ToastContent(
                variant: .info, title: "Tool Float",
                message: "\(activeFloatName ?? "This tool") is open. Close it to get back to your panes."))
    }

    private var noNewWorktreeToasts = ToastThrottle<SidebarController.NewWorktreeRefusal>()

    private func toastNoNewWorktree(_ refusal: SidebarController.NewWorktreeRefusal) {
        guard noNewWorktreeToasts.allows(refusal) else { return }
        toasts.show(ToastContent(variant: .info, title: "New Worktree", message: refusal.message))
    }

    private var activeWorkspace: WorkspaceController? { selection.workspace }

    private var activeController: TabController? { activeWorkspace?.activeController }

    private var activeTabIDs: [TabID] { activeWorkspace?.tabIDs ?? [] }

    private var allTabIDs: [TabID] { workspaces.flatMap(\.tabIDs) }

    private var allTabControllers: [TabController] { workspaces.flatMap(\.controllers) }

    // A tab's callbacks outlive its workspace being active, so every lookup by id searches all of them.
    private func workspace(of id: TabID) -> WorkspaceController? {
        workspaces.first { $0.tabIDs.contains(id) }
    }

    private func controller(_ id: TabID) -> TabController? { workspace(of: id)?.controller(id) }

    private func title(of id: TabID) -> String { workspace(of: id)?.title(id) ?? "shell" }

    private func attentionTitle(of id: TabID) -> String {
        guard workspaces.count > 1, let workspace = workspace(of: id) else { return title(of: id) }
        return "\(workspace.name): \(title(of: id))"
    }

    init(contentRect: NSRect, initialCWD: URL?) {
        window = HostWindow(contentRect: contentRect)
        windowID = WindowController.nextWindowID
        WindowController.nextWindowID += 1
        let firstID = TabID(1)
        let firstWorkspace = WorkspaceController(
            id: WorkspaceID(raw: 1), isConfigured: false, name: Self.unconfiguredName(among: []),
            folder: initialCWD ?? ShellLaunch.defaultCWD, firstTab: firstID)
        workspaces = [firstWorkspace]
        selection = .workspace(firstWorkspace)
        var onSelect: (TabID) -> Void = { _ in }
        var onClose: (TabID) -> Void = { _ in }
        var onRename: (TabID) -> Void = { _ in }
        var directoryOf: (TabID) -> URL? = { _ in nil }
        var onNewTab: () -> Void = {}
        tabBar = TabBarView(
            onSelect: { onSelect($0) },
            onClose: { onClose($0) },
            onRename: { onRename($0) },
            directory: { directoryOf($0) })
        var onSplitH: () -> Void = {}
        var onSplitV: () -> Void = {}
        var onPalette: () -> Void = {}
        var onSettings: () -> Void = {}
        var onToggleSidebar: () -> Void = {}
        var onActivateRow: (SidebarRowID) -> Void = { _ in }
        var onNewWorktree: (SidebarRowID) -> Void = { _ in }
        var onCloseWorkspace: (WorkspaceID) -> Void = { _ in }
        var onOpenWorkspace: () -> Void = {}
        var onBottom: () -> Void = {}
        var onRight: () -> Void = {}
        var onZoom: () -> Void = {}
        var onToolFloat: (ToolFloat) -> Void = { _ in }
        dock = ToggleDock(
            onNewTab: { onNewTab() },
            onSplitH: { onSplitH() }, onSplitV: { onSplitV() },
            onBottom: { onBottom() },
            onRight: { onRight() }, onZoom: { onZoom() },
            toolFloats: ToolFloatCatalog.userDefined, onToolFloat: { onToolFloat($0) },
            hiddenButtons: GeneralConfig.current.hiddenToolbarButtons)
        sidebar = SidebarController(
            onPalette: { onPalette() }, onSettings: { onSettings() }, onToggle: { onToggleSidebar() },
            onActivate: { onActivateRow($0) }, onNewWorktree: { onNewWorktree($0) },
            onCloseWorkspace: { onCloseWorkspace($0) }, onAdd: { onOpenWorkspace() })
        super.init()
        nextTabID = 2

        onSelect = { [weak self] in self?.select($0) }
        onClose = { [weak self] in self?.requestCloseTab($0) }
        onRename = { [weak self] in self?.openRenameTab($0) }
        directoryOf = { [weak self] id in self?.workspace(of: id)?.controller(id)?.focusedCWD }
        onNewTab = { [weak self] in self?.newTab() }
        onSplitH = { [weak self] in self?.handle(.splitHorizontal) }
        onSplitV = { [weak self] in self?.handle(.splitVertical) }
        onPalette = { [weak self] in self?.handle(.toggleCommandPalette) }
        onSettings = { [weak self] in self?.handle(.openSettings) }
        onToggleSidebar = { [weak self] in self?.handle(.toggleSidebar) }
        sidebar.onLeave = { [weak self] in self?.restoreFocusToActive() }
        sidebar.onFocusChanged = { [weak self] in
            self?.syncWindowFocus()
            self?.sidebar.edgeReveal.recheck()
        }
        sidebar.isPinnedExternally = { [weak self] in self?.isConfirmOpen ?? false }
        sidebar.onRevealChanged = { [weak self] in self?.syncWindowFocus() }
        sidebar.onFocusYield = { [weak self] in self?.captureFocusReturn() }
        sidebar.onFocusRestore = { [weak self] in self?.restoreFocusToActive() }
        sidebar.edgeReveal.isSuppressed = { [weak self] in
            guard let self else { return true }
            return sidebar.isDocked || isModalOverlayOpen || isToolFloatOpen || !windowIsKey
                || NSEvent.pressedMouseButtons != 0
        }
        onActivateRow = { [weak self] in self?.activateFromSidebar($0) }
        onNewWorktree = { [weak self] in self?.createWorktreeFromSidebar($0) }
        onCloseWorkspace = { [weak self] in self?.requestCloseWorkspace(id: $0) }
        sidebar.onJump = { [weak self] in self?.jumpToAgent($0) }
        sidebar.onJumpElsewhere = { [weak self] in self?.jumpToWaitingElsewhere() }
        sidebar.onActivateHost = { [weak self] host in
            self?.sidebar.hideReveal()
            self?.activate(host)
        }
        onOpenWorkspace = { [weak self] in self?.handle(.toggleRepoPicker) }
        onBottom = { [weak self] in self?.handle(.toggleBottomDrawer) }
        onRight = { [weak self] in self?.handle(.toggleRightDrawer) }
        onZoom = { [weak self] in self?.handle(.toggleZoom) }
        onToolFloat = { [weak self] spec in self?.handle(.toggleToolFloat(spec.id)) }

        firstWorkspace.setController(makeController(cwd: initialCWD), for: firstID)

        layoutContainer()
        yieldSidebarIfNarrow()
        window.delegate = self
        wireModes()
        attention.onChange = { [weak self] in self?.renderAttention() }

        attentionObserver = NotificationCenter.default.addObserver(
            forName: .attentionCenterDidChange, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? Int != self.windowID else { return }
                self.renderAgents()
            }
        }

        hostStatusObserver = NotificationCenter.default.addObserver(
            forName: .sshHostStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderTabBar() }
        }

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
                    self.sidebar.reapplyChromeLayout()
                    for controller in self.allTabControllers { controller.reapplyChromeLayout() }
                    self.reapplyFloatLayout()
                    self.reapplyModalLayout()
                    self.builtToasts?.reapplyInsets(
                        topInset: Self.toastTopInset, trailingInset: Self.toastTrailingInset)
                }
                if change.contains(.theme) || change.contains(.keymap)
                    || change.contains(.terminalBehavior)
                {
                    for controller in self.allTabControllers { controller.reapplyChromeColors() }
                }
                if change.contains(.theme) || change.contains(.terminalBehavior) {
                    self.floats.reapplyTheme()
                }
                if change.contains(.theme) {
                    self.tabBar.reapplyTheme()
                    self.dock.reapplyTheme()
                    self.sidebar.reapplyTheme()
                    self.confirmToast?.reapplyTheme()
                    self.attentionCards.values.forEach { $0.reapplyTheme() }
                    self.fontSizeCard?.reapplyTheme()
                    self.connectView?.reapplyTheme()
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
                    self.sidebar.setHiddenButtons(GeneralConfig.current.hiddenToolbarButtons)
                    self.renderDock()
                }
                if change.contains(.sshHosts) {
                    self.leaveRemovedHost(shownHosts: self.sidebar.hostIDs)
                    self.renderTabBar()
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
        canvasHost.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.wantsLayer = true
        container.addSubview(canvasHost)
        container.addSubview(tabBar)
        container.addSubview(dock)
        sidebar.install(in: container, besideTabBar: tabBar)
        sidebar.setHiddenButtons(GeneralConfig.current.hiddenToolbarButtons)
        NSLayoutConstraint.activate([
            canvasHost.leadingAnchor.constraint(equalTo: sidebar.edgeAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvasHost.topAnchor.constraint(equalTo: container.topAnchor),
            canvasHost.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            dock.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            dock.centerYAnchor.constraint(equalTo: tabBar.chipBandCenterYAnchor),
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
        let floatHoldsMode = active && floats.shownSurface != nil
        let tabHoldsMode = active && !floatHoldsMode
        floats.setFocusedSurfaceRendersFocused(!floatHoldsMode)
        if let previous = modeRenderTarget, previous !== activeController {
            previous.setFocusedSurfaceRendersFocused(true)
        }
        modeRenderTarget = tabHoldsMode ? activeController : nil
        activeController?.setFocusedSurfaceRendersFocused(!tabHoldsMode)
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
        for workspace in workspaces {
            for id in workspace.tabIDs {
                guard let c = workspace.controller(id) else { continue }
                let t = c.title
                if workspace.title(id) != t { workspace.setTitle(t, for: id); changed = true }
            }
        }
        if changed { renderTabBar() }

        if busyDots() != lastBusyDots { renderDock() }
        trackAgentExits()
        checkForRemovedWorktrees()
        sidebar.refreshBranches()
    }

    private var isCheckingForRemovedWorktrees = false

    private func checkForRemovedWorktrees() {
        let roots = workspaces.compactMap(\.origin?.path)
        guard !isCheckingForRemovedWorktrees, !roots.isEmpty else { return }
        isCheckingForRemovedWorktrees = true
        GitRepoStatus.removedWorktrees(among: roots) { [weak self] removed in
            self?.isCheckingForRemovedWorktrees = false
            self?.markRemovedWorktrees(removed)
        }
    }

    private func markRemovedWorktrees(_ removed: Set<URL>) {
        var changed = false
        for workspace in workspaces {
            guard let origin = workspace.origin, !worktreeRemovals.isRemoving(origin.path) else { continue }
            let isRemoved = removed.contains(origin.path)
            guard workspace.isWorktreeRemoved != isRemoved else { continue }
            workspace.isWorktreeRemoved = isRemoved
            changed = true
            if isRemoved {
                presentWorktreeRemovedToast(for: workspace.id, named: origin.name)
            } else if let toast = worktreeRemovedToasts[workspace.id] {
                toasts.dismiss(toast)
            }
        }
        guard changed else { return }
        renderTabBar()
        refreshOpenPicker()
        onWorktreeMarkChanged?()
    }

    func refreshOpenPicker() {
        (modal?.overlay as? RepoPickerOverlay)?.refreshOpen(
            runningWorkspaces(), elsewhere: openWorkspacesElsewhere?() ?? [])
    }

    private var worktreeRemovedToasts: [WorkspaceID: ToastView] = [:]

    private func presentWorktreeRemovedToast(for id: WorkspaceID, named name: String) {
        let close = ToastAction(title: "Close Workspace", kind: .primary) { [weak self] in
            guard let self, let toast = self.worktreeRemovedToasts[id] else { return }
            self.toasts.dismiss(toast)
            self.requestCloseWorkspace(id: id)
        }
        let toast = toasts.showSticky(
            ToastContent(variant: .warning, title: "Worktree Removed", message: "\(name) is no longer on disk."),
            actions: [close], showsClose: true)
        toast.onClose = { [weak self, weak toast] in toast.map { self?.toasts.dismiss($0) } }
        toast.onDismissed = { [weak self, weak toast] in
            guard let self, let toast, self.worktreeRemovedToasts[id] === toast else { return }
            self.worktreeRemovedToasts[id] = nil
        }
        worktreeRemovedToasts[id] = toast
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

    private func makeController(
        cwd: URL?, config ws: Workspace? = nil, tab index: Int = 0, connection: SSHConnection? = nil
    ) -> TabController {
        let tab = ws?.tabs[index]
        let mainCommand = tab?.main.flatMap { $0 == "shell" ? nil : $0 }
        let c = TabController(
            initialCWD: cwd, initialCommand: mainCommand, env: ws?.env ?? [:],
            isToolFloatOpen: { [weak self] in self?.floats.isOpen ?? false },
            startSurface: connection.map { connection in
                { [weak connection] surface, id, launch in
                    connection?.start(surface, id: id, env: launch.environment)
                }
            } ?? startSurfaceNow)
        c.rightDrawerCommand = tab?.right
        c.bottomDrawerCommand = tab?.bottom
        c.pinnedTitle = tab?.name
        return c
    }

    private func mintTabID() -> TabID { defer { nextTabID += 1 }; return TabID(nextTabID) }

    private func mintWorkspaceID() -> WorkspaceID {
        defer { nextWorkspaceID += 1 }
        return WorkspaceID(raw: nextWorkspaceID)
    }

    private static func unconfiguredName(among names: [String]) -> String {
        let taken = Set(names)
        var number = 1
        while taken.contains("Workspace \(number)") { number += 1 }
        return "Workspace \(number)"
    }

    enum SlideEdge { case fromRight, fromLeft, fromBottom, fromTop }

    enum MountTransition {
        case instant
        case slide(from: SlideEdge)
    }

    private var selectedCanvas: NSView? {
        switch selection {
        case .workspace(let workspace): return workspace.activeController?.view
        case .host(let host): return hostConnectView(for: host)
        }
    }

    private func hostConnectView(for host: SSHHostID) -> HostConnectView {
        if let connectView, connectView.host == host { return connectView }
        let view = HostConnectView(host: host) { [weak self] in self?.connect(host) }
        connectView = view
        return view
    }

    private func mount(_ transition: MountTransition) {
        guard let canvas = selectedCanvas else { return unmountCanvas() }
        guard mountedCanvas !== canvas else {
            restoreFocusToActive()
            renderDock()
            return
        }
        let outgoing = mountedCanvas
        pinCanvas(canvas)
        if let outgoing {
            canvasHost.addSubview(canvas, positioned: .above, relativeTo: outgoing)
        }
        mountedCanvas = canvas
        restoreFocusToActive()
        renderDock()

        switch transition {
        case .instant:
            outgoing?.removeFromSuperview()
        case .slide(let edge):
            container.layoutSubtreeIfNeeded()
            beginCanvasSlide(from: edge)
            Motion.slideSwap(incoming: canvas, outgoing: outgoing, offset: slideOffset(from: edge)) { [weak self] in
                self?.detachIfInactive(outgoing)
                self?.endCanvasSlide()
            }
        }
    }

    private func unmountCanvas() {
        restoreFocusToActive()
        mountedCanvas?.removeFromSuperview()
        mountedCanvas = nil
        renderDock()
    }

    private func slideOffset(from edge: SlideEdge) -> CGVector {
        let width = canvasHost.bounds.width + Self.slideFadeDepth
        let height = canvasHost.bounds.height + Self.slideFadeDepth
        switch edge {
        case .fromRight: return CGVector(dx: width, dy: 0)
        case .fromLeft: return CGVector(dx: -width, dy: 0)
        case .fromBottom: return CGVector(dx: 0, dy: -height)
        case .fromTop: return CGVector(dx: 0, dy: height)
        }
    }

    private func beginCanvasSlide(from edge: SlideEdge) {
        activeCanvasSlides += 1
        canvasHost.layer?.mask = slideFade(crossing: edge).layer
    }

    private func slideFade(crossing edge: SlideEdge) -> EdgeFade {
        let bounds = canvasHost.bounds
        let depth = Self.slideFadeDepth
        switch edge {
        case .fromRight, .fromLeft:
            let reach = sidebar.isDocked ? depth : 0
            horizontalSlideFade.update(
                frame: CGRect(x: -reach, y: 0, width: bounds.width + reach, height: bounds.height), start: reach,
                end: 0)
            return horizontalSlideFade
        case .fromBottom, .fromTop:
            verticalSlideFade.update(
                frame: CGRect(x: 0, y: -depth, width: bounds.width, height: bounds.height + depth), start: depth,
                end: 0)
            return verticalSlideFade
        }
    }

    private func endCanvasSlide() {
        activeCanvasSlides = max(0, activeCanvasSlides - 1)
        if activeCanvasSlides == 0 { canvasHost.layer?.mask = nil }
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
        if canvas.superview === canvasHost {
            canvasHost.addSubview(canvas, positioned: .below, relativeTo: nil)
            return
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.addSubview(canvas, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: sidebar.canvasLeadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: canvasHost.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: tabBar.topAnchor, constant: -ChromeMetrics.footerGap),
        ])
    }

    private func closeFloatForTabChange() { floats.close() }

    private func focusActive() {
        if floats.isOpen {
            floats.refocus()
        } else if let activeController {
            activeController.restoreUnifiedFocus()
        } else if activeWorkspace == nil {
            window.makeFirstResponder(connectView?.connectButton)
        }
    }

    private func captureFocusReturn() {
        focusReturn = sidebar.hasFocus ? sidebar.focusedStop : nil
    }

    private func returnFocusAfterOverlay() {
        let stop = focusReturn
        focusReturn = nil
        if let stop, sidebar.focusStop(stop) { return }
        restoreFocusToActive()
    }

    // An open card holds the keyboard until it closes, and closing it comes back through here.
    private func restoreFocusToActive() {
        if modal == nil { focusActive() }
        syncWindowFocus()
        if floats.isOpen { answerFocusedAgent() }
    }

    // One surface reports focused: the focused one in the key window's active tab, as libghostty's own apprt does.
    private func syncWindowFocus() {
        let holdsKeyFocus = windowIsKey && !sidebar.hasFocus
        activeController?.setHaloVisible(holdsKeyFocus && !sidebar.isRevealed)
        for controller in allTabControllers {
            controller.setHoldsKeyFocus(holdsKeyFocus && controller === activeController)
        }
        floats.setHoldsKeyFocus(holdsKeyFocus)
    }

    // Below `tabBar`, so the ⌘W guard toast fired over an open float stays visible.
    private func presentWindowFloat(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .below, relativeTo: tabBar)
        let gutter = ChromeMetrics.windowGutter
        let insets = (
            leading: overlay.leadingAnchor.constraint(equalTo: sidebar.canvasLeadingAnchor, constant: gutter),
            trailing: overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -gutter),
            top: overlay.topAnchor.constraint(
                equalTo: container.topAnchor, constant: ChromeMetrics.topInset),
            bottom: overlay.bottomAnchor.constraint(
                equalTo: tabBar.topAnchor, constant: -ChromeMetrics.footerGap)
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
            bottom: overlay.bottomAnchor.constraint(
                equalTo: tabBar.topAnchor, constant: -ChromeMetrics.footerGap)
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
        floatGutter.bottom.constant = -ChromeMetrics.footerGap
    }

    private func reapplyModalLayout() {
        guard let modalGutter else { return }
        let gutter = ChromeMetrics.windowGutter
        modalGutter.leading.constant = gutter
        modalGutter.trailing.constant = -gutter
        modalGutter.top.constant = ChromeMetrics.topInset
        modalGutter.bottom.constant = -ChromeMetrics.footerGap
    }

    private func newTab() {
        cancelConfirm()
        addTab(cwd: ShellLaunch.newSessionCWD(focused: activeController?.sessionCWD))
    }

    private func addTab(cwd: URL?) {
        guard let workspace = activeWorkspace else { return }
        Log.info("tab opened", category: .tabs)
        closeModal()
        closeFloatForTabChange()
        let id = mintTabID()
        workspace.add(id)
        installController(id: id, in: workspace, cwd: cwd, config: nil, transition: .slide(from: .fromRight))
    }

    private func installController(
        id: TabID, in workspace: WorkspaceController, cwd: URL?, config: Workspace?, tab index: Int = 0,
        transition: MountTransition
    ) {
        let c = makeController(cwd: cwd, config: config, tab: index, connection: workspace.connection)
        workspace.setController(c, for: id)
        wire(c, id: id)
        mount(transition)
        c.start()
        if let config {
            c.applyRecipe(config.tabs[index], focus: config.focus.tab == index ? config.focus.region : .main)
        }
        renderTabBar()
    }

    private func select(_ id: TabID, slideFrom: SlideEdge? = nil) {
        closeModal()
        guard let workspace = activeWorkspace, workspace.tabIDs.contains(id), id != workspace.activeID else { return }
        Log.info("tab switched", category: .tabs)
        closeFloatForTabChange()
        cancelConfirm()
        let oldIndex = workspace.activeID.flatMap { workspace.tabIDs.firstIndex(of: $0) } ?? 0
        workspace.select(id)
        visit(id)
        let newIndex = workspace.tabIDs.firstIndex(of: id) ?? 0
        mount(.slide(from: slideFrom ?? (newIndex > oldIndex ? .fromRight : .fromLeft)))
        renderAttention()
    }

    /// Brings a tab on screen wherever it lives: its workspace first, then the tab itself.
    private func reveal(_ id: TabID) {
        guard let workspace = workspace(of: id) else { return }
        guard workspace === activeWorkspace else {
            workspace.select(id)
            activate(workspace.id)
            return
        }
        select(id)
    }

    /// Swaps the whole canvas. An inactive workspace is detached and retained, the same as an inactive tab.
    private func activate(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), workspace !== activeWorkspace
        else { return }
        Log.info("workspace switched", category: .tabs)
        closeModal()
        closeFloatForTabChange()
        cancelConfirm()
        let transition = workspaceSlide(from: activeWorkspace?.id, to: id)
        selection = .workspace(workspace)
        mount(transition)
        if let tab = workspace.activeID { visit(tab) }
        renderAttention()
    }

    func activate(_ host: SSHHostID) {
        if revealOpenHost(host) { return }
        guard host != selection.host else { restoreFocusToActive(); return }
        Log.info("ssh host selected", category: .workspace)
        closeModal()
        closeFloatForTabChange()
        cancelConfirm()
        endModes()
        selection = .host(host)
        mount(.instant)
        renderAttention()
    }

    // Leaves an open card up, since a host is usually removed from inside Settings.
    private func leaveRemovedHost(shownHosts: [SSHHostID]) {
        guard case .host(let host) = selection, !GeneralConfig.current.sshHosts.contains(host.name) else { return }
        let current = order
        let reachable = Set(current.navigable)
        let place = shownHosts.firstIndex(of: host) ?? shownHosts.count
        let nearest = (shownHosts[min(place + 1, shownHosts.count)...] + shownHosts[..<place].reversed())
            .map(WorkspaceOrder.Target.host)
            .first(where: reachable.contains)
        guard let landing = nearest ?? current.navigableWorkspaces.first.map(WorkspaceOrder.Target.workspace)
        else { return }
        switch landing {
        case .workspace(let id):
            guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
            selection = .workspace(workspace)
            mount(.instant)
            if let tab = workspace.activeID { visit(tab) }
        case .host(let next):
            selection = .host(next)
            mount(.instant)
        }
        renderAttention()
    }

    private func workspaceSlide(from old: WorkspaceID?, to new: WorkspaceID) -> MountTransition {
        let ids = order.navigableWorkspaces
        guard let old, let from = ids.firstIndex(of: old), let to = ids.firstIndex(of: new) else { return .instant }
        return .slide(from: to > from ? .fromBottom : .fromTop)
    }

    private func cycleTab(_ delta: Int) {
        let ids = activeTabIDs
        guard ids.count > 1, let active = activeWorkspace?.activeID,
            let i = ids.firstIndex(of: active)
        else { return }
        select(ids[(i + delta + ids.count) % ids.count], slideFrom: delta > 0 ? .fromRight : .fromLeft)
    }

    private func activateFromSidebar(_ row: SidebarRowID) {
        sidebar.hideReveal()
        switch row {
        case .workspace(let id):
            guard id != activeWorkspace?.id else { restoreFocusToActive(); return }
            activate(id)
        case .ghost(let path):
            guard let parent = ghostParent(at: path) else { return }
            ConfigLoader.loadWorkspaces { [weak self] entries in
                self?.openWorkspace(entries.first { $0.path.standardizedFileURL.path == path } ?? parent)
            }
        }
    }

    private func ghostParent(at path: String) -> Workspace? {
        workspaces.lazy.compactMap(\.origin?.parent).first { $0.path.standardizedFileURL.path == path }
    }

    private var order: WorkspaceOrder {
        let hosts = GeneralConfig.current.sshHosts.map(SSHHostID.init).map {
            WorkspaceOrder.Host(id: $0, status: SSHHostStatusCenter.shared.status(of: $0))
        }
        return WorkspaceOrder(workspaces, hosts: hosts)
    }

    private var selectedTarget: WorkspaceOrder.Target? {
        selection.host.map(WorkspaceOrder.Target.host) ?? activeWorkspace.map { .workspace($0.id) }
    }

    private func activate(_ target: WorkspaceOrder.Target) {
        switch target {
        case .workspace(let id): activate(id)
        case .host(let host): activate(host)
        }
    }

    private func cycleWorkspace(_ delta: Int) {
        guard let current = selectedTarget, let next = order.stop(after: current, delta) else { return }
        activate(next)
    }

    private func moveActiveTab(_ delta: Int) {
        guard let workspace = activeWorkspace, let id = workspace.activeID, workspace.move(id, by: delta) else {
            return
        }
        Log.info("tab moved", category: .tabs)
        renderTabBar()
    }

    private func openRenameTab(_ id: TabID) {
        guard let controller = controller(id) else { return }
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
        guard let workspace = workspace(of: id), let controller = workspace.controller(id) else { return }
        controller.pinnedTitle = name.isEmpty ? nil : name
        workspace.setTitle(controller.title, for: id)
        renderTabBar()
    }

    private func closeTab(_ id: TabID, dismissingModal: Bool = true) {
        Log.info("tab closed", category: .tabs)
        guard let workspace = workspace(of: id) else { return }
        // A background workspace's tab closes without touching what is on screen, or it answers the wrong tab.
        let isOnScreen = workspace === activeWorkspace
        if isOnScreen {
            if dismissingModal { closeModal() }
            closeFloatForTabChange()
            cancelConfirm()
        }
        let tabController = workspace.controller(id)
        if mountedCanvas === tabController?.view {
            tabController?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        tabController?.surfaceIDs.forEach {
            agents.drop($0)
            agentStates.drop($0)
        }
        tabController?.shutdown()
        floats.shutdownScope(id)
        clearAttention(id)
        attention.dropTab(id)
        guard workspace.close(id) else { return closeWorkspace(workspace) }
        if isOnScreen {
            if let active = activeWorkspace?.activeID { visit(active) }
            mount(.instant)
        }
        renderAttention()
    }

    private func closeWorkspace(_ workspace: WorkspaceController) {
        Log.info("workspace closed", category: .workspace)
        if let host = workspace.host { return closeHostWorkspace(workspace, returningTo: host) }
        guard let place = order.navigableWorkspaces.firstIndex(of: workspace.id) else { return }
        workspaces.removeAll { $0 === workspace }
        worktreeRemovedToasts[workspace.id].map(toasts.dismiss)
        guard !workspaces.isEmpty else { window.close(); return }
        guard workspace === activeWorkspace else { renderAttention(); return }
        let remaining = order.navigableWorkspaces
        let landing = remaining.isEmpty ? workspaces.first?.id : remaining[min(place, remaining.count - 1)]
        guard let next = workspaces.first(where: { $0.id == landing }) else { return }
        selection = .workspace(next)
        mount(.slide(from: place < remaining.count ? .fromBottom : .fromTop))
        if let tab = next.activeID { visit(tab) }
        renderAttention()
    }

    private func closeHostWorkspace(_ workspace: WorkspaceController, returningTo host: SSHHostID) {
        workspaces.removeAll { $0 === workspace }
        workspace.shutdown()
        guard workspace === activeWorkspace else { renderAttention(); return }
        selection = .host(host)
        mount(.instant)
        renderAttention()
    }

    // One live session per host across the app: an open one is jumped to, never opened a second time.
    private func revealOpenHost(_ host: SSHHostID) -> Bool {
        if let open = workspaces.first(where: { $0.host == host }) {
            activate(open.id)
            return true
        }
        return revealHostInAnotherWindow?(host) == true
    }

    private func connect(_ host: SSHHostID) {
        guard selection.host == host, activeWorkspace == nil, !revealOpenHost(host) else { return }
        Log.info("ssh host connecting", category: .workspace)
        let connection = SSHConnection(host: host)
        connection.onConnectedChange = { SSHHostStatusCenter.shared.setConnected($0, host: host) }
        let tab = mintTabID()
        let workspace = WorkspaceController(
            id: mintWorkspaceID(), isConfigured: false, name: host.name, folder: ShellLaunch.defaultCWD,
            firstTab: tab, connection: connection)
        connection.onLoginFailed = { [weak self, weak workspace] in
            DispatchQueue.main.async { self?.loginFailed(on: host, closing: workspace) }
        }
        workspaces.append(workspace)
        activate(workspace.id)
        installController(id: tab, in: workspace, cwd: nil, config: nil, transition: .instant)
    }

    private func loginFailed(on host: SSHHostID, closing workspace: WorkspaceController?) {
        if let workspace, workspaces.contains(where: { $0 === workspace }) { closeTabs(of: workspace) }
        toasts.show(ToastContent(variant: .warning, title: "SSH Host", message: Self.connectFailedMessage(for: host)))
    }

    static func connectFailedMessage(for host: SSHHostID) -> String {
        let line = "Couldn't connect to \(host.name)."
        let width = (line as NSString).size(withAttributes: [.font: ToastView.messageFont]).width
        return width <= ToastView.messageMaxWidth ? line : "Couldn't connect to\n\(host.name)."
    }

    private func toastFloatsStayLocal(on host: SSHHostID) {
        toasts.show(
            ToastContent(
                variant: .info, title: "Tool Floats", message: "Tool floats run on this Mac, not on \(host.name)."))
    }

    func holdsHost(_ host: SSHHostID) -> Bool { workspaces.contains { $0.host == host } }

    private func presentModal(_ overlay: ModalOverlay, kind: ModalKind) {
        if let activeWorkspace, activeWorkspace.activeController == nil { return }
        captureFocusReturn()
        endModes()
        floats.cancelPendingOpen()
        pendingModal = nil
        presentWindowModal(overlay)
        modal = (overlay, kind)
        sidebar.setHoverCovered(true)
        overlay.focusInitialResponder()
        overlay.animateIn()
        renderDock()
    }

    private func closeModal() {
        pendingModal = nil
        guard let overlay = modal?.overlay else { return }
        modal = nil
        sidebar.setHoverCovered(false)
        modalGutter = nil
        overlay.animateOut { overlay.removeFromSuperview() }
        returnFocusAfterOverlay()
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
                open: self.runningWorkspaces(),
                elsewhere: self.openWorkspacesElsewhere?() ?? [],
                background: Theme.current.chrome.background.nsColor,
                removals: self.worktreeRemovals,
                openState: { [weak self] path in self?.workspaceOpenState(at: path) ?? .closed },
                onChoose: { [weak self] ws, origin in self?.openWorkspace(ws, origin: origin) },
                onSwitch: { [weak self] id in
                    self?.closeModal()
                    self?.activate(id)
                },
                onReveal: { [weak self] window, id in
                    guard self?.revealWorkspaceElsewhere?(window, id) == true else { return false }
                    self?.closeModal()
                    return true
                },
                onAddWorkspace: { [weak self] in self?.openAddWorkspaceForm() },
                onNewWorkspace: { [weak self] in self?.newWorkspace() },
                onDismiss: { [weak self] in self?.closeModal() }
            )
            self.presentModal(picker, kind: .repoPicker)
        }
    }

    private func toggleCommandPalette() {
        if modal?.kind == .commandPalette { closeModal(); return }
        let palette = CommandPaletteOverlay(
            commands: { [weak self] in
                CommandCatalog.commands(
                    tabCount: self?.activeTabIDs.count ?? 0,
                    workspaceCount: self?.workspaces.count ?? 0)
            },
            background: Theme.current.chrome.background.nsColor,
            onRun: { [weak self] chord in self?.runCommand(chord) },
            onDismiss: { [weak self] in self?.closeModal() }
        )
        presentModal(palette, kind: .commandPalette)
    }

    private func openAddWorkspaceForm() {
        openWorkspaceForm(editing: nil, returningTo: { [weak self] in self?.closeModal() })
    }

    private func createWorktreeFromPicker() {
        guard let picker = modal?.overlay as? RepoPickerOverlay, let target = picker.createTarget
        else { return }
        closeModal()
        presentNewWorktree(
            target, onCancel: { [weak self] in self?.reopenRepoPicker() },
            afterEdit: { [weak self] in self?.reopenRepoPicker() })
    }

    private func createWorktreeFromSidebar(_ row: SidebarRowID) {
        switch row {
        case .workspace(let id):
            guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
            presentNewWorktree(forEntryAt: workspace.folder, named: workspace.name)
        case .ghost(let path):
            guard let parent = ghostParent(at: path) else { return }
            presentNewWorktree(forEntryAt: parent.path, named: parent.title)
        }
    }

    // Reads the entry fresh, so the card copies what the file says now.
    private func presentNewWorktree(forEntryAt folder: URL, named name: String) {
        closeModal()
        pendingModal = .worktreeForm
        let path = folder.standardizedFileURL.path
        ConfigLoader.loadWorkspaces { [weak self] entries in
            guard let self, self.pendingModal == .worktreeForm else { return }
            guard let entry = entries.first(where: { $0.path.standardizedFileURL.path == path }) else {
                self.pendingModal = nil
                self.toasts.show(
                    ToastContent(
                        variant: .warning, title: "Couldn't Open New Worktree",
                        message: "\(name) is no longer in the workspaces file."))
                return
            }
            self.presentNewWorktree(
                RepoPickerOverlay.CreateTarget(workspace: entry, repo: entry.path),
                onCancel: { [weak self] in self?.closeModal() },
                afterEdit: { [weak self] in self?.presentNewWorktree(forEntryAt: entry.path, named: entry.title) },
                afterSave: { [weak self] saved in self?.presentNewWorktree(forEntryAt: saved.path, named: saved.title) }
            )
        }
    }

    private func presentNewWorktree(
        _ target: RepoPickerOverlay.CreateTarget, onCancel: @escaping () -> Void,
        afterEdit: @escaping () -> Void, afterSave: ((Workspace) -> Void)? = nil
    ) {
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
                onCancel: onCancel,
                onDismiss: { [weak self] in self?.closeModal() },
                onEditWorkspace: { [weak self] in
                    self?.openWorkspaceForm(editing: target.workspace, returningTo: afterEdit, onSaved: afterSave)
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak card] in
            let result: Result<(Workspace, WorktreeOrigin, CarryReport), Error>
            do {
                let worktree: Worktree
                switch request {
                case .newBranch(let branch, let base):
                    worktree = try WorktreeStore.create(branch: branch, base: base, in: target.repo)
                case .existingBranch(let branch):
                    worktree = try WorktreeStore.create(existingBranch: branch, in: target.repo)
                }
                let repoRoot = GitRepo.repoRoot(for: workspace.path)
                let opened = RepoPickerOverlay.workspace(
                    for: worktree, parent: workspace, repoRoot: repoRoot)
                let report = WorktreeCarry.copy(
                    workspace.carry, from: workspace.path, intoCheckout: worktree.path,
                    repoRoot: repoRoot,
                    onEntry: { name in
                        DispatchQueue.main.async { [weak self, weak card] in
                            guard let card, self?.isPresenting(card) == true else { return }
                            card.setPhase("Copying \(name)")
                        }
                    })
                result = .success((opened, WorktreeOrigin(parent: workspace, worktree: worktree), report))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self, weak card] in
                guard let self else { return }
                let stillUp = card.map(self.isPresenting) ?? false
                switch result {
                case .success(let (opened, origin, report)):
                    if stillUp { self.closeModal() }
                    self.openWorkspace(opened, origin: origin)
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
        guard let picker = modal?.overlay as? RepoPickerOverlay else { return }
        if let removed = picker.selectedRemovedWorkspace { return closeRemovedWorkspace(removed) }
        guard let selection = picker.selectedWorktree else { return }
        let (worktree, parent) = selection
        let closes = onClosedByRemovalAtPath?(worktree.path) ?? closedByRemoval(atPath: worktree.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let carried = parent.carry.compactMap { entry -> String? in
                let url = worktree.path.appendingPathComponent(entry)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return PathDisplay.isDirectory(url) ? entry + "/" : entry
            }
            let items = WorktreeRemovalMessage.items(
                for: worktree, state: WorktreeStore.state(worktree), carried: carried, closes: closes)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.modal?.overlay === picker,
                    !self.worktreeRemovals.isRemoving(worktree.path)
                else { return }
                self.confirmRemoveWorktree(picker, worktree, from: parent, items: items)
            }
        }
    }

    private var otherWindowCloseToasts = ToastThrottle<Bool>()

    private func closeRemovedWorkspace(_ running: RunningWorkspace) {
        guard running.window == windowID, let id = running.id else {
            guard otherWindowCloseToasts.allows() else { return }
            toasts.show(
                ToastContent(
                    variant: .info, title: "Open in Another Window",
                    message: "Close \(running.removedWorktreeName ?? running.name) from the window it is open in."))
            return
        }
        closeModal()
        requestCloseWorkspace(id: id)
    }

    // A card, not the toast confirm, because this deletes a folder and cannot be undone.
    private func confirmRemoveWorktree(
        _ picker: RepoPickerOverlay, _ worktree: Worktree, from parent: Workspace,
        items: [ConfirmCardChecklist.Item]
    ) {
        let name = worktree.name
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

    private enum SettingsLanding { case top, tools, workspaces, terminal, appearance, general, shortcuts, sshHosts }

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
            "scroll-multiplier", "shell", "shell-args", "tab-inherit-cwd":
            return .terminal
        case "theme", "accent-color", "window-chrome", "backdrop-alpha", "window-gutter", "pane-gap",
            "bottom-drawer-fraction", "right-drawer-fraction", "drawer-resize-step", "max-drawer-fraction",
            "reduce-motion", "hide-toolbar-buttons":
            return .appearance
        case "agents", "agent-notifications", "attention-toast", "completion-toast", "toast-duration",
            "automatic-update-checks":
            return .general
        case "ssh-hosts":
            return .sshHosts
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
        case .sshHosts: return "SSH Hosts"
        }
    }

    #if DEBUG
        static func settingsLandingNavTitleForTesting(for scope: ConfigDiagnostic.Scope) -> String? {
            navTitle(for: landing(for: scope))
        }
    #endif

    private func openSettings(landing: SettingsLanding = .top, focusingSSHHost host: String? = nil) {
        if modal?.kind == .settings { closeModal(); return }
        let toolsSection = SettingsToolsSection()
        toolsSection.onEditFloat = { [weak self] float in self?.openToolFloatForm(editing: float) }
        toolsSection.onReorder = { [weak self] floats in self?.reorderToolFloats(floats) }
        let workspacesSection = SettingsWorkspacesSection()
        workspacesSection.onEditWorkspace = { [weak self] ws in self?.openWorkspaceForm(editing: ws) }
        workspacesSection.onReorder = { [weak self] moved, neighbour in
            self?.reorderWorkspaces(moved, with: neighbour) ?? false
        }
        let sshHostsSection = SettingsSSHHostsSection()
        sshHostsSection.onAddHost = { [weak self] in self?.openAddSSHHost() }
        sshHostsSection.hostToFocus = host
        let sections: [SettingsSection] = [
            SettingsAppearanceSection(),
            SettingsGeneralSection(),
            SettingsTerminalSection(),
            SettingsKeybindsSection(capturer: keybindCapturer),
            toolsSection,
            workspacesSection,
            sshHostsSection,
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

    private func openAddSSHHost() {
        closeModal()
        let overlay = AddSSHHostOverlay(
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { [weak self] host in self?.addSSHHost(host) },
            onCancel: { [weak self] in self?.reopenSettingsOnSSHHosts() })
        presentModal(overlay, kind: .sshHostForm)
    }

    private func addSSHHost(_ host: String) {
        do {
            try SSHHostsWriter.set(host, on: true)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Add SSH Host",
                    message: "Couldn't save \(host) to ZenTerm's config: \(error.localizedDescription)"))
            return
        }
        AppConfig.reload()
        reopenSettingsOnSSHHosts(focusing: host)
    }

    private func reopenSettingsOnSSHHosts(focusing host: String? = nil) {
        closeModal()
        openSettings(landing: .sshHosts, focusingSSHHost: host)
    }

    private func reopenSettingsOnTools() {
        closeModal()
        openSettings(landing: .tools)
    }

    private func openWorkspaceForm(
        editing workspace: Workspace?, returningTo done: (() -> Void)? = nil,
        onSaved: ((Workspace) -> Void)? = nil
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
            let form = WorkspaceFormOverlay(
                editing: workspace,
                existingTitles: existingTitles,
                background: Theme.current.chrome.background.nsColor,
                onSubmit: { [weak self] built in
                    if let originalTitle {
                        self?.submitWorkspace(
                            built, replacing: originalTitle, then: onSaved.map { saved in { saved(built) } } ?? done)
                    } else {
                        self?.submitNewWorkspace(built)
                    }
                },
                onCancel: done,
                onDelete: workspace.map { existing in
                    { [weak self] in self?.deleteWorkspace(existing, then: done) }
                }
            )
            self.presentModal(form, kind: .workspaceForm)
        }
    }

    private func submitWorkspace(_ ws: Workspace, replacing originalTitle: String, then done: @escaping () -> Void) {
        do {
            try WorkspacesWriter.update(ws, originalTitle: originalTitle)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Save Workspace",
                    message: "Failed to write \(ws.title) to the workspaces file: \(error.localizedDescription)"))
            return
        }
        done()
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
        openWorkspace(ws)
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
        // After the card closes, not before: closing it is what hands focus back to the row it was opened from.
        closeModal()
        endModes()
        if sidebar.hasFocus { focusReturn = sidebar.focusedStop ?? focusReturn }
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
        returnFocusAfterOverlay()
        sidebar.edgeReveal.recheck()
        renderDock()
    }

    private func openWorkspace(at path: URL) -> WorkspaceController? {
        let target = path.standardizedFileURL.path
        return workspaces.first { $0.isConfigured && $0.folder.standardizedFileURL.path == target }
    }

    func holdsWorkspace(at path: URL) -> Bool { openWorkspace(at: path) != nil }

    func activateWorkspace(at path: URL) {
        guard let workspace = openWorkspace(at: path) else { return }
        activate(workspace.id)
    }

    // In the sidebar's order, so the picker's Open section reads the way the rows beside it do.
    func runningWorkspaces() -> [RunningWorkspace] {
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        return order.entries.compactMap { entry in
            switch entry {
            case .workspace(let id):
                guard let workspace = byID[id] else { return nil }
                return RunningWorkspace(
                    window: windowID, id: id, name: workspace.name, folder: workspace.folder,
                    isWorktree: false, removedWorktreeName: nil)
            case .worktree(let id):
                guard let workspace = byID[id] else { return nil }
                return RunningWorkspace(
                    window: windowID, id: id, name: workspace.name, folder: workspace.folder,
                    isWorktree: true, removedWorktreeName: workspace.isWorktreeRemoved ? workspace.origin?.name : nil)
            case .ghost(let parent):
                return RunningWorkspace(
                    window: windowID, id: nil, name: parent.title, folder: parent.path, isWorktree: false,
                    removedWorktreeName: nil)
            }
        }
    }

    func holdsWorkspace(_ id: WorkspaceID) -> Bool { workspaces.contains { $0.id == id } }

    func activateWorkspace(_ id: WorkspaceID) { activate(id) }

    private func workspaceOpenState(at path: URL) -> WorkspaceOpenState {
        if holdsWorkspace(at: path) { return .here }
        return isWorkspaceOpenInAnotherWindow?(path) == true ? .elsewhere : .closed
    }

    private func openWorkspace(_ ws: Workspace, origin: WorktreeOrigin? = nil) {
        closeModal()
        if let open = openWorkspace(at: ws.path) {
            activate(open.id)
            return
        }
        if revealWorkspaceInAnotherWindow?(ws.path) == true { return }
        appendWorkspace(named: ws.title, at: ws.path, config: ws, origin: origin)
    }

    // The home folder, not the focused pane's: a workspace is a place, and folder identity makes two on one folder collide.
    private func newWorkspace() {
        closeModal()
        appendWorkspace(
            named: Self.unconfiguredName(among: workspaces.map(\.name)), at: ShellLaunch.defaultCWD, config: nil)
    }

    private func appendWorkspace(
        named name: String, at folder: URL, config: Workspace?, origin: WorktreeOrigin? = nil
    ) {
        Log.info("workspace opened", category: .workspace)
        let tabs = (0..<(config?.tabs.count ?? 1)).map { _ in mintTabID() }
        let group = config.map { _ in (origin?.parent.path ?? folder).standardizedFileURL.path }
        let seat = group.flatMap { group in workspaces.first { WorkspaceOrder.groupFolder(of: $0) == group }?.seat }
        let workspace = WorkspaceController(
            id: mintWorkspaceID(), isConfigured: config != nil, name: name, folder: folder, firstTab: tabs[0],
            origin: origin, seat: seat)
        workspaces.append(workspace)
        activate(workspace.id)
        for (index, tab) in tabs.enumerated() {
            if index > 0 { workspace.add(tab) }
            installController(id: tab, in: workspace, cwd: folder, config: config, tab: index, transition: .instant)
        }
        guard let config, tabs[config.focus.tab] != workspace.activeID else { return }
        workspace.select(tabs[config.focus.tab])
        mount(.instant)
        renderTabBar()
    }

    func handle(_ chord: KeyInterceptor.ReservedChord) {
        if let activeWorkspace, activeWorkspace.activeID == nil { return }
        closingModalKind = nil
        let active = activeController
        if isConfirmOpen { return }
        if let modal {
            if modal.overlay.isShowingOverlaidCard { return }
            if let selfToggle = modal.kind.selfToggle, chord == selfToggle {
                closeModal()
                return
            }
            if modal.overlay.handle(chord) { return }
            if modal.kind == .repoPicker, chord == .createWorktree {
                createWorktreeFromPicker()
                return
            }
            if modal.kind == .repoPicker, chord == .removeWorktree {
                removeSelectedWorktreeInPicker()
                return
            }
            if modal.kind == .repoPicker, chord == .newWorkspace {
                newWorkspace()
                return
            }
            switch chord {
            case .toggleSidebar:
                toggleSidebar()
                return
            case .toggleRepoPicker, .toggleCommandPalette, .openSettings, .toggleToolFloat, .reportIssue,
                .newTool:
                guard activeWorkspace != nil || chord.worksWithoutTab else { return }
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
            case .navLeft, .navRight, .navUp, .navDown, .prevPane, .nextPane, .focusSidebar,
                .splitVertical, .splitHorizontal,
                .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
                .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom:
                toastFloatBlocked()
                return
            case .toggleCommandPalette, .toggleRepoPicker, .openSettings, .reportIssue, .newTool,
                .renameTab:
                floats.close()
            case .toggleToolFloat, .newTab, .newWindow, .closeTab, .closeWindow,
                .selectTab, .prevTab, .nextTab,
                .moveTabLeft, .moveTabRight, .fillScreen, .toggleSidebar,
                .increaseFontSize, .decreaseFontSize, .resetFontSize, .selectAll,
                .toggleScrollMode, .toggleSearch, .searchSelection, .findNext, .findPrevious,
                .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown, .scrollToSelection,
                .jumpToPreviousPrompt, .jumpToNextPrompt, .pasteSelection, .clearScreen,
                .writeScreenFile, .copyScreenFilePath, .openScreenFile,
                .dismissToast, .dismissAllToasts,
                .selectWorkspace, .prevWorkspace, .nextWorkspace, .closeWorkspace, .newWorkspace,
                .nextWaitingAgent:
                break
            default:
                return
            }
        }
        if case .host(let host) = selection {
            if chord == .newTab { return connect(host) }
            if chord == .navRight, sidebar.hasFocus { return restoreFocusToActive() }
        }
        guard activeWorkspace != nil || chord.worksWithoutTab else { return }
        switch chord {
        case .splitVertical:
            Log.info("pane split (vertical)", category: .panes)
            active?.split(.vertical)
        case .splitHorizontal:
            Log.info("pane split (horizontal)", category: .panes)
            active?.split(.horizontal)
        case .prevPane: active?.cyclePane(-1)
        case .nextPane: active?.cyclePane(1)
        case .navLeft: navigate(.left)
        case .navRight: navigate(.right)
        case .navUp: navigate(.up)
        case .navDown: navigate(.down)
        case .resizeLeft: active?.resize(.left)
        case .resizeRight: active?.resize(.right)
        case .resizeUp: active?.resize(.up)
        case .resizeDown: active?.resize(.down)
        case .newTab: newTab()
        case .selectTab(let n):
            let idx = n - 1
            let ids = activeTabIDs
            if idx >= 0 && idx < ids.count { select(ids[idx]) }
        case .prevTab: cycleTab(-1)
        case .nextTab: cycleTab(1)
        case .moveTabLeft: moveActiveTab(-1)
        case .moveTabRight: moveActiveTab(1)
        case .renameTab: activeWorkspace?.activeID.map { openRenameTab($0) }
        case .closePane:
            Log.info("close pane", category: .panes)
            requestClosePane()
        case .closeTab:
            Log.info("close tab", category: .tabs)
            activeWorkspace?.activeID.map(requestCloseTab)
        case .closeWindow:
            Log.info("close window", category: .tabs)
            requestCloseWindow()
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
        case .toggleSidebar: toggleSidebar()
        case .focusSidebar:
            if !sidebar.isShown { toggleSidebar() }
            if sidebar.isRevealed {
                endModes()
                sidebar.focusRevealedCard()
            } else {
                _ = focusSidebar()
            }
        case .toggleToolFloat(let id):
            pendingModal = nil
            if let host = activeWorkspace?.host { return toastFloatsStayLocal(on: host) }
            if let spec = ToolFloatCatalog.byID(id) { floats.toggle(spec) }
        case .toggleRepoPicker: toggleRepoPicker()
        case .createWorktree:
            if let row = sidebar.focusedWorktreeParent {
                createWorktreeFromSidebar(row)
            } else if let refusal = sidebar.focusedWorktreeRefusal {
                toastNoNewWorktree(refusal)
            }
        case .removeWorktree: break
        case .toggleCommandPalette: toggleCommandPalette()
        case .openSettings: openSettings()
        case .reportIssue: openReportIssue()
        case .newTool: openToolFloatForm(editing: nil, returnTo: toolFormReturnForNewTool())
        case .selectWorkspace(let n):
            let stops = order.navigable
            if stops.indices.contains(n - 1) { activate(stops[n - 1]) }
        case .prevWorkspace: cycleWorkspace(-1)
        case .nextWorkspace: cycleWorkspace(1)
        case .nextWaitingAgent: jumpToNextWaitingAgent()
        case .closeWorkspace:
            Log.info("close workspace", category: .workspace)
            if let activeWorkspace { requestCloseWorkspace(activeWorkspace) }
        case .newWorkspace: newWorkspace()
        }
    }

    private func navigate(_ direction: Direction) {
        guard sidebar.hasFocus else { activeController?.navigate(direction); return }
        if direction == .right { restoreFocusToActive() } else { activeController?.toastNoNeighbor(direction) }
    }

    private func focusSidebar() -> Bool {
        guard sidebar.isDocked else { return false }
        endModes()
        sidebar.focusActiveRow()
        return true
    }

    private func toggleSidebar() {
        Log.info("sidebar toggled", category: .workspace)
        if sidebar.hasFocus { restoreFocusToActive() }
        guard canDockSidebar else {
            sidebar.toggleFloat()
            return
        }
        let onScreen = (activeController?.allSurfaces ?? []) + [floats.shownSurface].compactMap { $0 }
        sidebar.toggle(holding: onScreen, in: container)
    }

    private var canDockSidebar: Bool {
        window.contentWidth >= SidebarController.minimumDockableWidth
    }

    private func yieldSidebarIfNarrow() {
        guard !canDockSidebar else { return }
        sidebar.yieldToNarrowWindow(in: container)
    }

    private var preFillFrame: NSRect?

    private func toggleFillScreen() {
        let animate = !Motion.isReduceMotionEnabled()
        if let restore = preFillFrame {
            preFillFrame = nil
            window.setFrameWithinLimits(restore, animate: animate)
            return
        }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        preFillFrame = window.frame
        window.setFrame(visible, display: true, animate: animate)
    }

    var tabCount: Int { allTabIDs.count }

    func selectTab(_ id: TabID) { reveal(id) }

    func clearActiveTabNotification() {
        guard let id = activeWorkspace?.activeID else { return }
        AgentNotifier.shared.clear(windowID: windowID, tabID: id)
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

        if let workspace = activeWorkspace, isAwaitingLogin(on: active.focusedSurfaceID) {
            return confirmAbandoningLogin(of: workspace, closing: active.isDrawerFocused ? .drawer : .pane)
        }
        if active.isDrawerFocused {
            guard active.focusedDrawerIsBusy else { active.closeFocusedDrawer(); return }
            presentConfirm(
                variant: .warning, title: CloseWarning.Subject.drawer.title,
                message: CloseWarning.message(closing: .drawer, naming: []),
                confirmLabel: "Close"
            ) { [weak self] in self?.activeController?.closeFocusedDrawer() }
            return
        }

        let lastPane = active.isSinglePane
        if lastPane, let workspace = activeWorkspace, let tab = workspace.activeID, holdsAwaitingLogin(tab: tab) {
            return confirmAbandoningLogin(of: workspace, closing: .tab)
        }
        let closesWindow = lastPane && activeTabIDs.count == 1 && closesWindow(closing: activeWorkspace)
        let needsConfirm =
            closesWindow
            || active.focusedPaneIsBusy
            || (lastPane && activeWorkspace?.activeID.map(isRunning(tab:)) ?? false)
        guard needsConfirm else {
            if active.closeFocused() == false { activeWorkspace?.activeID.map { closeTab($0) } }
            return
        }

        let subject: CloseWarning.Subject =
            closesWindow ? .lastPane(running: windowIsRunning) : (lastPane ? .tab : .pane)
        let names =
            closesWindow
            ? runningNamesInWindow()
            : (lastPane ? activeWorkspace?.activeID.map(hiddenRunningNames(inTab:)) ?? [] : [])
        presentConfirm(
            variant: .warning, title: subject.title,
            message: CloseWarning.message(closing: subject, naming: names), confirmLabel: "Close"
        ) { [weak self] in
            guard let self, let active = self.activeController else { return }
            if active.closeFocused() == false { self.activeWorkspace?.activeID.map { self.closeTab($0) } }
        }
    }

    private func isAwaitingLogin(on surface: SurfaceID?) -> Bool {
        activeWorkspace?.connection?.isAwaitingLogin(on: surface) ?? false
    }

    private func holdsAwaitingLogin(tab id: TabID) -> Bool {
        guard let connection = workspace(of: id)?.connection, let tab = controller(id) else { return false }
        return tab.surfaceIDs.contains { connection.isAwaitingLogin(on: $0) }
    }

    private func holdsAwaitingLogin(_ workspace: WorkspaceController) -> Bool {
        workspace.tabIDs.contains(where: holdsAwaitingLogin(tab:))
    }

    private func confirmAbandoningLogin(of workspace: WorkspaceController, closing target: CloseWarning.LoginTarget) {
        guard let host = workspace.host else { return }
        let subject = CloseWarning.Subject.login(host: host.name, closing: target)
        presentConfirm(
            variant: .warning, title: subject.title,
            message: CloseWarning.message(closing: subject, naming: []), confirmLabel: "Close"
        ) { [weak self, weak workspace] in
            guard let self, let workspace, self.workspaces.contains(where: { $0 === workspace }) else { return }
            self.abandonLogin(of: workspace)
        }
    }

    private func abandonLogin(of workspace: WorkspaceController) {
        Log.info("ssh login closed before connecting", category: .workspace)
        workspace.connection?.shutdown()
        closeTabs(of: workspace)
    }

    private func requestCloseTab(_ id: TabID) {
        guard let workspace = workspace(of: id) else { return }
        if holdsAwaitingLogin(tab: id) { return confirmAbandoningLogin(of: workspace, closing: .tab) }
        let closesWindow = workspace.tabIDs.count == 1 && closesWindow(closing: workspace)
        guard closesWindow || isRunning(tab: id) else { closeTab(id); return }
        let subject: CloseWarning.Subject =
            closesWindow ? .lastTab(running: windowIsRunning) : .tab
        let names = closesWindow ? runningNamesInWindow() : hiddenRunningNames(inTab: id)
        presentConfirm(
            variant: .warning, title: subject.title,
            message: CloseWarning.message(closing: subject, naming: names),
            confirmLabel: "Close"
        ) { [weak self] in self?.closeTab(id) }
    }

    func requestCloseWorkspace(id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        requestCloseWorkspace(workspace)
    }

    private func requestCloseWorkspace(_ workspace: WorkspaceController) {
        if holdsAwaitingLogin(workspace) { return confirmAbandoningLogin(of: workspace, closing: .workspace) }
        let closesWindow = closesWindow(closing: workspace)
        guard closesWindow || isRunning(workspace: workspace) else {
            closeTabs(of: workspace)
            return
        }
        let subject: CloseWarning.Subject =
            closesWindow ? .lastWorkspace(running: windowIsRunning) : .workspace(workspace.name)
        let names = closesWindow ? runningNamesInWindow() : runningTabNames(in: workspace)
        presentConfirm(
            variant: .warning, title: subject.title,
            message: CloseWarning.message(closing: subject, naming: names),
            confirmLabel: "Close"
        ) { [weak self] in self?.closeTabs(of: workspace) }
    }

    // A host's workspace closes back to its Connect screen, so only a lone local workspace takes the window.
    private func closesWindow(closing workspace: WorkspaceController?) -> Bool {
        workspace?.host == nil && workspaces.count == 1
    }

    private func closeTabs(of workspace: WorkspaceController) {
        let background = workspace.tabIDs.filter { $0 != workspace.activeID }
        for id in background + [workspace.activeID].compactMap({ $0 }) { closeTab(id) }
    }

    private func requestCloseWindow() {
        guard windowIsRunning else {
            window.close()
            return
        }
        presentConfirm(
            variant: .warning, title: CloseWarning.Subject.window.title,
            message: CloseWarning.message(closing: .window, naming: runningNamesInWindow()),
            confirmLabel: "Close"
        ) { [weak self] in self?.window.close() }
    }

    private var windowIsRunning: Bool {
        workspaces.contains(where: isRunning(workspace:)) || floats.hasBusy
    }

    private func isRunning(tab id: TabID) -> Bool {
        controller(id)?.allSurfaces.contains(where: \.isBusy) == true || floats.hasBusyInScope(id)
            || holdsAwaitingLogin(tab: id)
    }

    private func isRunning(workspace: WorkspaceController) -> Bool {
        workspace.allSurfaces.contains(where: \.isBusy)
            || workspace.tabIDs.contains(where: floats.hasBusyInScope)
            || holdsAwaitingLogin(workspace)
    }

    private func hiddenRunningNames(inTab id: TabID) -> [String] {
        let drawers = (controller(id)?.hiddenRunningDrawers ?? []).map(Self.drawerName)
        return drawers + floats.hiddenRunningTitles(scope: id)
    }

    private func runningNamesInWindow() -> [String] {
        let named: [String]
        if workspaces.count > 1 {
            named = workspaces.filter(isRunning(workspace:)).map(\.name)
        } else if let activeWorkspace, activeWorkspace.tabIDs.count > 1 {
            named = runningTabNames(in: activeWorkspace)
        } else {
            named = activeWorkspace?.activeID.map(hiddenRunningNames(inTab:)) ?? []
        }
        return named + floats.hiddenRunningTitles(scope: nil)
    }

    private func runningTabNames(in workspace: WorkspaceController) -> [String] {
        workspace.tabIDs.filter(isRunning(tab:)).map(title(of:))
    }

    private static func drawerName(_ edge: DrawerEdge) -> String {
        switch edge {
        case .bottom: return "the bottom drawer"
        case .right: return "the right drawer"
        }
    }

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
            guard let self, let workspace = self.workspace(of: id), let c = workspace.controller(id)
            else { return }
            workspace.setTitle(c.title, for: id)
            self.renderAttention()
        }
        c.onLastPaneClosed = { [weak self] in self?.closeTab(id) }
        c.removedWorktree = { [weak self] in self?.workspace(of: id)?.removedWorktree }
        c.onOverlayStateChanged = { [weak self] in self?.renderDock() }
        c.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        c.onPaneStartFailed = { [weak self] retry, close in
            self?.presentSurfaceFailureToast(retry: retry, close: close)
        }
        c.onFocusChanged = { [weak self] in
            self?.cancelConfirm()
            self?.endModes()
            self?.answerFocusedAgent()
            self?.syncWindowFocus()
        }
        c.focusPastLeftEdge = { [weak self, weak c] in
            guard let self, c === self.activeController else { return false }
            return self.focusSidebar()
        }
        c.noNeighborHint = { [weak self] direction in
            guard let self, direction == .left, !sidebar.isDocked else { return nil }
            let chord = CommandCatalog.spec(for: .toggleSidebar).shortcut
            return chord.isEmpty ? nil : "Press \(chord) to show the sidebar."
        }
        c.onSurfaceEvent = { [weak self] surface, event in self?.report(surface, event) }
        c.onProgress = { [weak self] surface, progress in
            self?.progressChanged(surface: surface, progress: progress)
        }
        c.onTitle = { [weak self] surface, title in
            self?.titleChanged(surface: surface, title: title)
        }
        c.onSurfaceShown = { [weak self] surface in self?.surfaceShown(surface) }
        c.onSurfacesRegistered = { [weak self] ids in
            ids.forEach { self?.attention.register($0, tab: id) }
        }
        c.onSurfacesReleased = { [weak self] ids in
            self?.workspace(of: id)?.connection?.release(ids)
            ids.forEach {
                self?.attention.release($0)
                self?.agents.drop($0)
                self?.agentStates.drop($0)
            }
            self?.renderAgents()
        }
        c.onProgramLaunched = { [weak self] surface, command in self?.programLaunched(surface, command) }
        c.onNotification = { [weak self] surface, n in
            self?.agentNotified(surface: surface, id: id, notification: n)
        }
        c.onCommandFinished = { [weak self] surface, result in
            self?.commandFinished(surface: surface, id: id, result: result)
        }
    }

    // The banner lands on `owner`: a hidden Scratch asking for input is usually not in the active tab.
    private func floatNotified(
        surface: SurfaceID?, _ notification: TerminalNotification, from spec: ToolFloat, owner: TabID?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let activeID = self.activeWorkspace?.activeID else { return }
            let message = notification.body.isEmpty ? notification.title : notification.body
            let target = owner.flatMap { self.workspace(of: $0) == nil ? nil : $0 } ?? activeID
            let address = self.floatCardAddress(spec, owner: owner, target: target)
            self.land(
                notification, from: surface, on: target, seen: self.isFloatShown(spec, surface), address: address,
                message: message)
        }
    }

    private func agentNotified(surface: SurfaceID?, id: TabID, notification: TerminalNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.workspace(of: id) != nil else { return }
            let message = notification.body.isEmpty ? notification.title : notification.body
            self.land(
                notification, from: surface, on: id, seen: self.isSeen(surface, in: id),
                address: self.paneCardAddress(surface, in: id), message: message)
        }
    }

    private func land(
        _ notification: TerminalNotification, from surface: SurfaceID?, on id: TabID, seen: Bool, address: CardAddress,
        message: String
    ) {
        guard isFromAgent(surface, notification) else {
            return landNonAgentNotification(on: id, surface: surface, seen: seen, address: address, message: message)
        }
        switch notificationKind(surface, notification) {
        case .stateless:
            noteStatelessNotification(surface, notification)
        case .ask:
            landAsk(notification, from: surface, on: id, seen: seen, address: address, message: message)
        case .idlePrompt:
            landIdlePrompt(notification, from: surface, on: id, seen: seen, address: address, message: message)
        }
    }

    // Progress already caught the turn end, so the prompt only carries the banner a missed turn end still owes.
    private func landIdlePrompt(
        _ notification: TerminalNotification, from surface: SurfaceID?, on id: TabID, seen: Bool, address: CardAddress,
        message: String
    ) {
        guard let surface, agentStates.reportsProgress(surface) else {
            return landAsk(notification, from: surface, on: id, seen: seen, address: address, message: message)
        }
        if attention.agentWait(of: surface) == .turnEnd { pushBanner(for: id, address: address, message: message) }
    }

    private func landAsk(
        _ notification: TerminalNotification, from surface: SurfaceID?, on id: TabID, seen: Bool, address: CardAddress,
        message: String
    ) {
        pushBanner(for: id, address: address, message: message)
        surface.map { attention.ask($0, seen: seen) }
        surface.map { agentSignalled($0, name: notification.title, message: message) }
        renderAgents()
        guard !seen else { return }
        presentAttentionCard(.waiting, for: id, address: address, message: message, surface: surface)
    }

    private struct CardAddress {
        let title: () -> String
        let titleTail: String?
        let destination: CardDestination?
    }

    private func floatCardAddress(_ spec: ToolFloat, owner: TabID?, target: TabID) -> CardAddress {
        CardAddress(
            title: { [weak self] in owner == nil ? spec.title : self?.attentionTitle(of: target) ?? spec.title },
            titleTail: owner == nil ? nil : ": \(spec.title)",
            destination: CardDestination(
                shortcut: { CommandCatalog.spec(for: .toggleToolFloat(spec.id)).shortcut },
                open: { [weak self] in
                    guard let self else { return }
                    owner.map { self.reveal($0) }
                    if self.floats.activeID != spec.id { self.handle(.toggleToolFloat(spec.id)) }
                }))
    }

    private func paneCardAddress(_ surface: SurfaceID?, in id: TabID) -> CardAddress {
        let edge = drawerEdge(of: surface, in: id)
        return CardAddress(
            title: { [weak self] in self?.attentionTitle(of: id) ?? "" }, titleTail: drawerTail(edge),
            destination: edge.map { drawerDestination($0, in: id) })
    }

    private func cardAddress(of surface: SurfaceID, in id: TabID) -> CardAddress {
        guard let float = floats.float(of: surface) else { return paneCardAddress(surface, in: id) }
        return floatCardAddress(float.spec, owner: float.tab, target: id)
    }

    private func pushBanner(for id: TabID, address: CardAddress, message: String) {
        guard
            AgentNotifier.shouldPushNotification(
                appActive: NSApp.isActive, enabled: GeneralConfig.current.agentNotifications)
        else { return }
        AgentNotifier.shared.notify(
            windowID: windowID, tabID: id, title: address.title() + (address.titleTail ?? ""), body: message)
    }

    private func isFloatShown(_ spec: ToolFloat, _ surface: SurfaceID?) -> Bool {
        floats.activeID == spec.id && floats.surfaceID(spec.id) == surface && Self.isPresent(window)
    }

    private func isFromAgent(_ surface: SurfaceID?, _ notification: TerminalNotification) -> Bool {
        guard let surface, liveAgent(surface) == nil else { return true }
        return AgentRoster.agentName(notifying: notification.title, listed: GeneralConfig.current.listedAgents) != nil
    }

    // An exited agent stays listed until its latch is answered, and the shell back in its pane is not it.
    private func liveAgent(_ surface: SurfaceID) -> AgentRoster.Agent? {
        agents.agents[surface].flatMap { $0.hasExited ? nil : $0 }
    }

    private func notificationKind(
        _ surface: SurfaceID?, _ notification: TerminalNotification
    ) -> AgentRules.NotificationKind {
        let listed = surface.flatMap { liveAgent($0)?.name }
        let name = listed ?? (notification.title.isEmpty ? nil : notification.title)
        return AgentRules.notificationKind(body: notification.body, agentName: name)
    }

    private func noteStatelessNotification(_ surface: SurfaceID?, _ notification: TerminalNotification) {
        guard let surface else { return }
        agents.identify(surface, name: notification.title.isEmpty ? nil : notification.title, source: .signal)
        if !notification.body.isEmpty { agents.setMessage(surface, notification.body) }
        renderAgents()
    }

    private func landNonAgentNotification(
        on id: TabID, surface: SurfaceID?, seen: Bool, address: CardAddress, message: String
    ) {
        guard !seen, attention.state(tab: id) != .waiting else { return }
        surface.map { attention.record($0, .completed, seen: false) }
        presentAttentionCard(.completed(.positive), for: id, address: address, message: message, surface: surface)
        renderAttention()
    }

    private func raiseAskCard(_ surface: SurfaceID, in id: TabID, message: String) {
        let address = cardAddress(of: surface, in: id)
        pushBanner(for: id, address: address, message: message)
        presentAttentionCard(.waiting, for: id, address: address, message: message, surface: surface)
    }

    private func finishTurn(_ surface: SurfaceID) {
        guard let tab = tab(of: surface) else { return }
        attention.endTurn(surface, seen: isSeen(surface, in: tab))
        guard attention.agentWait(of: surface) == .turnEnd, !hasAskCard(tab) else { return }
        presentAttentionCard(
            .waiting, for: tab, address: cardAddress(of: surface, in: tab), message: Self.turnEndMessage,
            surface: surface)
    }

    // A tab shows one card, and a finished turn is never worth more than a question.
    private func hasAskCard(_ tab: TabID) -> Bool {
        cardSurfaces[tab].map { attention.agentWait(of: $0) == .ask } ?? false
    }

    private static let blockedMessage = "Waiting for your approval."

    private static let turnEndMessage = "Finished its turn."

    private func commandFinished(surface: SurfaceID?, id: TabID, result: TerminalCommandResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.workspace(of: id) != nil else { return }
            let crashedAgent = surface.map { self.agentExited($0, in: id, result: result) } ?? false
            guard !crashedAgent, !self.isSeen(surface, in: id),
                result.duration >= Self.commandCompletionThreshold,
                self.attention.state(tab: id) != .waiting
            else { return }

            surface.map { self.attention.record($0, .completed, seen: false) }
            self.presentAttentionCard(
                .completed(result.exitCode.map { $0 == 0 ? .positive : .warning } ?? .positive), for: id,
                address: self.paneCardAddress(surface, in: id), message: Self.commandResultMessage(result),
                surface: surface)
            self.renderAttention()
        }
    }

    // Only `indeterminate` means working: a determinate report is a real progress bar, not an agent turn.
    private func progressChanged(surface: SurfaceID, progress: TerminalProgress?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if progress?.state == .indeterminate, !self.attention.isWorking(surface) {
                self.agentSignalled(surface, name: "", message: nil)
            }
            guard self.agents.contains(surface) else { return }
            self.agentStates.noteProgress(AgentRules.progressRegion(progress), of: surface)
            self.deriveAgentState(surface)
        }
    }

    private func titleChanged(surface: SurfaceID, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var joined = false
            if !self.agents.contains(surface), let name = AgentRules.agentName(matching: title) {
                self.agents.identify(surface, name: name, source: .signal)
                joined = true
            }
            guard self.agents.contains(surface) else { return }
            let previous = self.agentStates.title(of: surface)
            self.agentStates.noteTitle(title, of: surface)
            if self.attention.agentWait(of: surface) != nil,
                AgentRules.isClaudeResuming(from: previous, to: title, agentName: self.agents.agents[surface]?.name)
            {
                self.answerAgent(surface)
            }
            if self.deriveAgentState(surface) { return }
            if self.agentStates.state(of: surface) == .working { self.noteTitleMessage(surface) }
            if joined { self.renderAgents() }
        }
    }

    // The tail is the live tool name, so it moves many times inside one turn the state never leaves.
    private func noteTitleMessage(_ surface: SurfaceID) {
        guard attention.agentWait(of: surface) == nil,
            let message = AgentRules.message(
                fromTitle: agentStates.title(of: surface), agentName: agents.agents[surface]?.name),
            agents.agents[surface]?.message != message
        else { return }
        agents.setMessage(surface, message)
        renderAgents()
    }

    @discardableResult
    private func deriveAgentState(_ surface: SurfaceID) -> Bool {
        guard let agent = agents.agents[surface] else { return false }
        let outcome = AgentStateEngine.evaluate(
            AgentRules.rules(for: agent.name), title: agentStates.title(of: surface),
            progress: agentStates.progress(of: surface))
        let wasHolding = agentStates.isHoldingIdle(surface)
        let wasBlocked = agentStates.state(of: surface) == .blocked
        guard let next = agentStates.publish(surface, outcome) else {
            if !wasHolding, agentStates.isHoldingIdle(surface) { settleIdleHold(surface) }
            return false
        }
        Log.info("agent \(agent.name ?? AgentRoster.unnamed): \(outcome.label)", category: .workspace)
        if attention.agentWait(of: surface) != nil, wasBlocked || resumesAfterAsking(next, agent: agent) {
            answerAgent(surface)
        }
        applyDerived(next, to: surface)
        return true
    }

    // An agent that stopped goes quiet, so no later signal arrives to end the hold.
    private func settleIdleHold(_ surface: SurfaceID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentStateTracker.idleHold) { [weak self] in
            guard let self, self.agentStates.isHoldingIdle(surface) else { return }
            self.deriveAgentState(surface)
        }
    }

    private func applyDerived(_ state: AgentSignalState, to surface: SurfaceID) {
        switch state {
        case .working:
            if attention.agentWait(of: surface) != .ask { takeDownCard(of: surface) }
            attention.setWorking(surface, true)
            noteTitleMessage(surface)
        case .idle:
            let endedTurn = attention.isWorking(surface)
            if endedTurn { answerAgent(surface) }
            attention.setWorking(surface, false)
            if attention.agentWait(of: surface) == nil { agents.setMessage(surface, nil) }
            if endedTurn, agents.agents[surface]?.name != nil { finishTurn(surface) }
        case .blocked:
            guard let tab = tab(of: surface) else { return }
            let seen = isSeen(surface, in: tab)
            attention.setWorking(surface, false)
            attention.ask(surface, seen: seen)
            guard !seen else { break }
            let message = AgentRules.codexAsk(fromTitle: agentStates.title(of: surface)) ?? Self.blockedMessage
            raiseAskCard(surface, in: tab, message: message)
        }
        renderAgents()
    }

    // A window float belongs to no tab, so it asks from whichever tab is showing it.
    private func tab(of surface: SurfaceID) -> TabID? {
        attention.tab(of: surface) ?? (floats.float(of: surface) != nil ? activeWorkspace?.activeID : nil)
    }

    // A shell reports a signal death as 128+n. SIGINT and SIGTERM are someone stopping the agent, not it failing.
    private static let deliberateStopCodes: Set<Int> = [130, 143]

    static func commandResultMessage(_ result: TerminalCommandResult) -> String {
        let elapsed = elapsedDescription(result.duration)
        guard let code = result.exitCode, code != 0 else { return "Finished in \(elapsed)." }
        if deliberateStopCodes.contains(code) { return "Stopped after \(elapsed)." }
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

    /// A card whose Switch opens something other than a tab, with that thing's own shortcut.
    private struct CardDestination {
        let shortcut: () -> String
        let open: () -> Void
    }

    private enum AttentionCard {
        case waiting
        case completed(ToastVariant)
    }

    private func presentAttentionCard(
        _ card: AttentionCard, for id: TabID, address: CardAddress, message: String, surface: SurfaceID?
    ) {
        let title = address.title
        let titleTail = address.titleTail
        if let old = attentionCards[id] { toasts.dismiss(old) }
        let content: ToastContent
        let dismissal: GeneralConfig.ToastDismissal
        switch card {
        case .waiting:
            content = ToastContent(
                variant: .info, title: title(), titleTail: titleTail, message: message, icon: "bell.fill")
            dismissal = GeneralConfig.current.attentionToast
        case .completed(let variant):
            content = ToastContent(variant: variant, title: title(), titleTail: titleTail, message: message)
            dismissal = GeneralConfig.current.completionToast
        }
        let destination =
            address.destination
            ?? CardDestination(
                shortcut: { [weak self] in self?.switchShortcut(for: id) ?? "" },
                open: { [weak self] in self?.reveal(id) })
        let actions = [
            ToastAction(title: "Dismiss", kind: .cancel) { [weak self] in
                self?.answer(id, surface: surface)
            },
            ToastAction(title: "Switch", kind: .primary, shortcut: destination.shortcut) {
                destination.open()
            },
        ]
        attentionCards[id] = mountAttentionToast(
            for: id, surface: surface, content: content, title: title, actions: actions,
            autoDismiss: dismissal == .auto)
    }

    private func drawerEdge(of surface: SurfaceID?, in id: TabID) -> DrawerEdge? {
        guard let surface, let drawers = controller(id)?.drawerSurfaceIDs else { return nil }
        if surface == drawers.right { return .right }
        if surface == drawers.bottom { return .bottom }
        return nil
    }

    /// The part of a card's title naming the drawer that asked, after its tab's name.
    private func drawerTail(_ edge: DrawerEdge?) -> String? {
        edge.map { $0 == .right ? ": right drawer" : ": bottom drawer" }
    }

    /// Switch on a drawer's card opens the drawer, in its own tab: selecting a tab you are already in does nothing.
    private func drawerDestination(_ edge: DrawerEdge, in id: TabID) -> CardDestination {
        let chord: KeyInterceptor.ReservedChord = edge == .right ? .toggleRightDrawer : .toggleBottomDrawer
        return CardDestination(
            shortcut: { CommandCatalog.spec(for: chord).shortcut },
            open: { [weak self] in
                guard let self else { return }
                self.reveal(id)
                let overlay = self.controller(id)?.overlayState
                let isOpen = edge == .right ? overlay?.isRightOpen : overlay?.isBottomOpen
                if isOpen != true { self.handle(chord) }
            })
    }

    // Layout is not enough: a pane you can see in a window you are not in has not been seen.
    private func isSeen(_ surface: SurfaceID?, in id: TabID) -> Bool {
        if let surface, let float = floats.float(of: surface) { return isFloatShown(float.spec, surface) }
        return isOnScreen(surface, in: id) && Self.isPresent(window)
    }

    /// A surface is on screen while its tab is active and, for a drawer, the drawer is open.
    private func isOnScreen(_ surface: SurfaceID?, in id: TabID) -> Bool {
        guard id == activeWorkspace?.activeID else { return false }
        guard let surface else { return true }
        return controller(id)?.isOnScreen(surface) ?? true
    }

    // Presence, not just focus: an agent that speaks while you are in another app has not been seen.
    static var isPresent: (NSWindow) -> Bool = { NSApp.isActive && $0.isKeyWindow }

    private var presentFocusedSurface: SurfaceID? {
        Self.isPresent(window) ? focusedSurface : nil
    }

    private var focusedSurface: SurfaceID? {
        guard modal == nil, !sidebar.hasFocus else { return nil }
        if let float = floats.activeID { return floats.surfaceID(float) }
        return activeController?.focusedSurfaceID
    }

    // Coming on screen answers the toast, the tab and a finished turn, never an ask: looking is not answering.
    private func answerFocusedAgent() {
        if let surface = presentFocusedSurface {
            attention.markSeen(surface)
        }
        renderAttention()
    }

    // Runs on every keystroke the chrome passed on, which includes ones the find field takes before the pane.
    func answerTypedAgent() {
        guard !search.isEditing, let surface = presentFocusedSurface,
            attention.agentWait(of: surface) != nil, !awaitsSignalAnswer(surface)
        else { return }
        answerAgent(surface)
    }

    // An arrow key at a prompt sends nothing, so an agent that signals its own answer is never answered by a key.
    private func awaitsSignalAnswer(_ surface: SurfaceID) -> Bool {
        guard let agent = liveAgent(surface) else { return false }
        return AgentRules.key(for: agent.name) != nil && attention.agentWait(of: surface) == .ask
    }

    private func resumesAfterAsking(_ next: AgentSignalState, agent: AgentRoster.Agent) -> Bool {
        next == .working && AgentRules.key(for: agent.name) != nil
    }

    // The row takes its tone from the store and its words from the roster, so both clear here or the row lies.
    private func answerAgent(_ surface: SurfaceID) {
        if attention.agentWait(of: surface) != nil { agents.setMessage(surface, nil) }
        attention.answerAgent(surface)
    }

    private func programLaunched(_ surface: SurfaceID, _ command: String) {
        guard let name = AgentRoster.agentName(launching: command, listed: GeneralConfig.current.listedAgents) else {
            return
        }
        agents.identify(surface, name: name, source: .launch)
        renderAgents()
    }

    private func agentSignalled(_ surface: SurfaceID, name: String, message: String?) {
        agents.identify(surface, name: name.isEmpty ? nil : name, source: .signal)
        agents.setMessage(surface, message)
    }

    // Only a named agent's crash asks; any other exit lands as a command finishing.
    private func agentExited(_ surface: SurfaceID, in id: TabID, result: TerminalCommandResult) -> Bool {
        guard let agent = agents.agents[surface] else { return false }
        let message = Self.commandResultMessage(result)
        exitsAwaitingResult.remove(surface)
        agents.markExited(surface, message: message)
        let crashed = agent.name != nil && Self.isCrash(result)
        if crashed {
            let seen = isSeen(surface, in: id)
            takeDownTurnEndCard(of: surface)
            attention.endCrashedAgent(surface, seen: seen)
            agentStates.drop(surface)
            if !seen { raiseAskCard(surface, in: id, message: message) }
        } else {
            endAgent(surface)
        }
        renderAgents()
        return crashed
    }

    private static func isCrash(_ result: TerminalCommandResult) -> Bool {
        result.exitCode.map { $0 != 0 && !deliberateStopCodes.contains($0) } ?? false
    }

    private func endAgent(_ surface: SurfaceID) {
        takeDownTurnEndCard(of: surface)
        attention.endAgent(surface)
        agentStates.drop(surface)
    }

    private func takeDownTurnEndCard(of surface: SurfaceID) {
        if attention.agentWait(of: surface) == .turnEnd { takeDownCard(of: surface) }
    }

    private func trackAgentExits() {
        let before = agents.agents
        let settling = exitsAwaitingResult
        exitsAwaitingResult = []
        for id in settling { endAgent(id) }
        for (id, agent) in before {
            agents.trackBusy(id, terminalSurface(id)?.isBusy ?? false)
            if !agent.hasExited, agents.agents[id]?.hasExited == true { exitsAwaitingResult.insert(id) }
            if agentStates.isHoldingIdle(id) { deriveAgentState(id) }
        }
        if !settling.isEmpty || agents.agents != before { renderAgents() }
    }

    private func terminalSurface(_ id: SurfaceID) -> TerminalSurface? {
        for workspace in workspaces {
            for tab in workspace.tabIDs {
                if let surface = workspace.controller(tab)?.surface(id) { return surface }
            }
        }
        return floats.surface(id)
    }

    private func renderAgents() {
        for (id, agent) in agents.agents
        where agent.hasExited && !exitsAwaitingResult.contains(id) && attention.agentWait(of: id) == nil
            && !attention.isWorking(id)
        {
            agents.drop(id)
            agentStates.drop(id)
        }
        let items = agentItems()
        sidebar.renderAgents(items)
        let center = AttentionCenter.shared
        sidebar.renderWaitingElsewhere(
            agents: center.waitingCount(excluding: windowID),
            windows: center.waitingWindows(excluding: windowID),
            index: waitingElsewherePlace(among: items))
    }

    // The row queues on the same rule the rows use: waiting first, and among those the oldest reads first.
    private func waitingElsewherePlace(among items: [SidebarAgentItem]) -> Int {
        guard let since = AttentionCenter.shared.waiting.first(where: { $0.windowID != windowID })?.since
        else { return items.count }
        return items.prefix {
            $0.state == .waiting && (attention.agentSince(of: $0.id) ?? .distantFuture) <= since
        }.count
    }

    private func jumpToWaitingElsewhere() {
        guard let target = AttentionCenter.shared.waiting.first(where: { $0.windowID != windowID })
        else { return }
        if revealWaitingAgentElsewhere?(target.windowID) != true { renderAgents() }
    }

    /// Lands on whatever has waited longest here, calling `raise` first. False, and nothing raised, when nothing waits.
    @discardableResult
    func revealLongestWaitingAgent(raising raise: () -> Void = {}) -> Bool {
        guard let target = attention.waitingInOrder.first else { return false }
        raise()
        switch target {
        case .surface(let id):
            jumpToAgent(id)
        case .tab(let id):
            reveal(id)
            visit(id)
            renderAttention()
        }
        return true
    }

    private func agentItems() -> [SidebarAgentItem] {
        typealias Ranked = (item: SidebarAgentItem, since: Date?, position: [Int])
        let located = agents.agents.compactMap { id, agent -> Ranked? in
            guard let place = agentPlace(id) else { return nil }
            let wait = attention.agentWait(of: id)
            let state = AttentionTone(wait: wait, working: attention.isWorking(id))
            let message = wait == .turnEnd ? Self.turnEndMessage : agent.message
            let item = SidebarAgentItem(
                id: id, state: state,
                summary: message.map(SidebarAgentItem.summaryLine) ?? state.summary,
                detail: "\(place.name) · \(agent.name ?? AgentRoster.unnamed)",
                message: message)
            return (item, attention.agentSince(of: id), place.position)
        }
        return located.sorted { a, b in
            if a.item.state.rank != b.item.state.rank { return a.item.state.rank < b.item.state.rank }
            if a.item.state == .waiting, a.since != b.since {
                return (a.since ?? .distantFuture) < (b.since ?? .distantFuture)
            }
            return a.position.lexicographicallyPrecedes(b.position)
        }.map(\.item)
    }

    // Sidebar position, so rows sharing a state keep still: workspace, tab, then the surface within it.
    private func agentPlace(_ id: SurfaceID) -> (name: String, position: [Int])? {
        if let float = floats.float(of: id) {
            let tab = float.tab.flatMap { tab in workspace(of: tab).map { (tab, $0) } }
            guard let (tab, workspace) = tab else { return (float.spec.title, [Int.max]) }
            return (workspace.name, place(of: tab, in: workspace) + [Int.max])
        }
        for workspace in workspaces {
            for tab in workspace.tabIDs {
                guard let index = workspace.controller(tab)?.surfaceIDs.firstIndex(of: id) else { continue }
                return (workspace.name, place(of: tab, in: workspace) + [index])
            }
        }
        return nil
    }

    private func place(of tab: TabID, in workspace: WorkspaceController) -> [Int] {
        [order.position(of: workspace.id) ?? 0, workspace.tabIDs.firstIndex(of: tab) ?? 0]
    }

    // Steps from where you are rather than tracking a cursor, so answering or a new wait cannot strand the cycle.
    private func jumpToNextWaitingAgent() {
        let waiting = agentItems().filter { $0.state == .waiting }
        guard !waiting.isEmpty else { return toastNothingWaiting() }
        let current = waiting.firstIndex { $0.id == focusedSurface }
        let next = waiting[((current ?? -1) + 1) % waiting.count]
        Log.info("jump to waiting agent", category: .workspace)
        jumpToAgent(next.id)
    }

    private func toastNothingWaiting() {
        let elsewhere = AttentionCenter.shared.waitingCount(excluding: windowID) > 0
        toasts.show(
            ToastContent(
                variant: .info,
                title: elsewhere ? "Waiting in another window" : "Nothing is waiting",
                message: elsewhere
                    ? "Nothing in this window is asking for you.\nThe sidebar row takes you there."
                    : "No agent in this window is asking for you.\nThe sidebar lists the ones that are."))
    }

    private func jumpToAgent(_ surface: SurfaceID) {
        if let float = floats.float(of: surface) {
            float.tab.map { reveal($0) }
            pendingModal = nil
            floats.reveal(surface)
        } else if let tab = attention.tab(of: surface) {
            reveal(tab)
            if floats.isOpen { closeFloatForTabChange() }
            controller(tab)?.focus(surface: surface)
        }
        answerFocusedAgent()
    }

    /// Answers whatever `surface` asked now that it is on screen, and takes down the card it raised.
    private func surfaceShown(_ surface: SurfaceID) {
        attention.markSeen(surface)
        answerFocusedAgent()
        takeDownCard(of: surface)
    }

    /// Clears the tab and the surface that asked. A window float belongs to no tab, so the tab alone would miss it.
    private func answer(_ id: TabID, surface: SurfaceID?) {
        surface.map { attention.markSeen($0) }
        clearAttention(id)
    }

    private func mountAttentionToast(
        for id: TabID, surface: SurfaceID? = nil, content: ToastContent, title: @escaping () -> String,
        actions: [ToastAction], autoDismiss: Bool
    ) -> ToastView {
        let toast = toasts.showSticky(content, actions: actions, autoDismiss: autoDismiss)
        cardSurfaces[id] = surface
        cardTitles[id] = title
        toast.onClose = { [weak self] in self?.answer(id, surface: surface) }
        toast.onDismissed = { [weak self, weak toast] in
            guard let self, let toast, self.attentionCards[id] === toast else { return }
            self.attentionCards[id] = nil
            self.cardSurfaces[id] = nil
            self.cardTitles[id] = nil
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

    func checkForRemovedWorktreesForTesting() { checkForRemovedWorktrees() }

    func presentModalForTesting(_ overlay: ModalOverlay) { presentModal(overlay, kind: .workspaceForm) }

    func openWorkspaceForTesting(_ ws: Workspace, origin: WorktreeOrigin? = nil) {
        openWorkspace(ws, origin: origin)
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
        guard activeTabIDs.indices.contains(tabIndex) else { return }
        notifyAgentForTesting(tab: activeTabIDs[tabIndex], message: message)
    }

    func waitingToastForTesting(tabIndex: Int) -> ToastView? {
        guard activeTabIDs.indices.contains(tabIndex) else { return nil }
        return attentionCards[activeTabIDs[tabIndex]]
    }

    func notifyCommandFinishedForTesting(tabIndex: Int, result: TerminalCommandResult) {
        guard activeTabIDs.indices.contains(tabIndex) else { return }
        let id = activeTabIDs[tabIndex]
        commandFinished(surface: controller(id)?.focusedSurfaceID, id: id, result: result)
    }

    func attentionStateForTesting(tabIndex: Int) -> TabAttentionState? {
        guard activeTabIDs.indices.contains(tabIndex) else { return nil }
        let state = attention.state(tab: activeTabIDs[tabIndex]).tabState
        return state == .idle ? nil : state
    }

    func notifyProgressForTesting(tabIndex: Int, progress: TerminalProgress?) {
        guard activeTabIDs.indices.contains(tabIndex),
            let surface = controller(activeTabIDs[tabIndex])?.focusedSurfaceID
        else { return }
        progressChanged(surface: surface, progress: progress)
    }

    var windowAttentionForTesting: SurfaceAttention { attention.windowState }

    var dockForTesting: ToggleDock { dock }

    func tabTitleForTesting(index: Int) -> String? {
        guard activeTabIDs.indices.contains(index) else { return nil }
        return title(of: activeTabIDs[index])
    }

    func surfaceAttentionForTesting(tabIndex: Int) -> SurfaceAttention? {
        guard activeTabIDs.indices.contains(tabIndex) else { return nil }
        return attention.state(tab: activeTabIDs[tabIndex])
    }

    func newTabForTesting() { handle(.newTab) }
    func closeTabForTesting(index: Int) {
        guard activeTabIDs.indices.contains(index) else { return }
        closeTab(activeTabIDs[index])
    }

    func selectTabForTesting(index: Int) {
        guard activeTabIDs.indices.contains(index) else { return }
        select(activeTabIDs[index])
    }

    func renameActiveTabForTesting(to name: String) {
        activeWorkspace?.activeID.map { renameTab($0, to: name) }
    }

    func renameTabForTesting(index: Int) {
        guard activeTabIDs.indices.contains(index) else { return }
        openRenameTab(activeTabIDs[index])
    }

    var floatsForTesting: ToolFloatController { floats }

    var tabOrderForTesting: [TabID] { activeTabIDs }
    var tabTitlesForTesting: [String] { activeTabIDs.map { title(of: $0) } }

    var activeTabIDForTesting: TabID? { activeWorkspace?.activeID }

    var workspaceIDsForTesting: [WorkspaceID] { workspaces.map(\.id) }

    var workspaceNamesForTesting: [String] { workspaces.map(\.name) }

    var sidebarForTesting: SidebarController { sidebar }

    var containerForTesting: NSView { container }

    var activeWorkspaceIDForTesting: WorkspaceID {
        guard let activeWorkspace else { preconditionFailure("the window has a host selected") }
        return activeWorkspace.id
    }

    var selectedHostForTesting: SSHHostID? { selection.host }

    var connectViewForTesting: HostConnectView? { mountedCanvas as? HostConnectView }

    var activeConnectionForTesting: SSHConnection? { activeWorkspace?.connection }

    func selectHostForTesting(_ host: SSHHostID) {
        selection = .host(host)
        mount(.instant)
        renderAttention()
    }

    func addWorkspaceForTesting(name: String, folder: URL) -> WorkspaceID {
        let id = mintTabID()
        let workspace = WorkspaceController(
            id: mintWorkspaceID(), isConfigured: true, name: name, folder: folder, firstTab: id)
        workspaces.append(workspace)
        let controller = makeController(cwd: folder)
        workspace.setController(controller, for: id)
        wire(controller, id: id)
        controller.start()
        return workspace.id
    }

    func activateWorkspaceForTesting(_ id: WorkspaceID) { activate(id) }

    func tabIDsForTesting(workspace id: WorkspaceID) -> [TabID] {
        workspaces.first { $0.id == id }?.tabIDs ?? []
    }

    func controllerForTesting(tab id: TabID) -> TabController? { controller(id) }

    func notifyAgentForTesting(tab id: TabID, message: String) {
        let surface = controller(id)?.focusedSurfaceID
        surface.map { agents.identify($0, name: nil, source: .signal) }
        agentNotified(surface: surface, id: id, notification: TerminalNotification(title: "", body: message))
    }

    func attentionStateForTesting(tab id: TabID) -> SurfaceAttention { attention.state(tab: id) }

    func agentStateForTesting(_ surface: SurfaceID) -> AttentionTone {
        AttentionTone(wait: attention.agentWait(of: surface), working: attention.isWorking(surface))
    }

    func agentWaitForTesting(_ surface: SurfaceID) -> AttentionStore.AgentWait? { attention.agentWait(of: surface) }

    func agentRowForTesting(_ surface: SurfaceID) -> SidebarAgentItem? {
        agentItems().first { $0.id == surface }
    }

    var focusedSurfaceIDForTesting: SurfaceID? { activeController?.focusedSurfaceID }

    func trackAgentExitsForTesting() { trackAgentExits() }

    func terminalSurfaceForTesting(_ surface: SurfaceID) -> TerminalSurface? { terminalSurface(surface) }

    func identifyAgentForTesting(_ surface: SurfaceID, name: String) {
        agents.identify(surface, name: name, source: .launch)
    }

    func agentMessageForTesting(_ surface: SurfaceID) -> String? { agents.agents[surface]?.message }

    func waitingToastForTesting(tab id: TabID) -> ToastView? { attentionCards[id] }

    func notifyCommandFinishedForTesting(tab id: TabID, result: TerminalCommandResult) {
        commandFinished(surface: controller(id)?.focusedSurfaceID, id: id, result: result)
    }

    func closeTabForTesting(tab id: TabID) { closeTab(id) }

    func workspaceAttentionForTesting(_ id: WorkspaceID) -> SurfaceAttention {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return .idle }
        return attention.state(tabs: workspace.tabIDs)
    }

    var hasBuiltToastsForTesting: Bool { builtToasts != nil }

    var backdropTintColorForTesting: NSColor? {
        tint.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }

    private func clearAttention(_ id: TabID) {
        attention.markSeen(tab: id)
        takeDownCard(id)
    }

    /// Answers what the tab shows on arrival; a closed drawer or Scratch keeps its dot and card.
    private func visit(_ id: TabID) {
        attention.visit(id) { isOnScreen($0, in: id) }
        answerFocusedAgent()
        if isOnScreen(cardSurfaces[id], in: id) { takeDownCard(id) }
    }

    private func takeDownCard(of surface: SurfaceID) {
        guard let id = cardSurfaces.first(where: { $0.value == surface })?.key else { return }
        takeDownCard(id)
    }

    private func takeDownCard(_ id: TabID) {
        cardSurfaces[id] = nil
        cardTitles[id] = nil
        if let toast = attentionCards.removeValue(forKey: id) { toasts.dismiss(toast) }
        AgentNotifier.shared.clear(windowID: windowID, tabID: id)
    }

    /// The tab number and the dock's dots are the same signal at two altitudes, so they move together.
    private func renderAttention() {
        renderTabBar()
        renderDock()
        publishAttention()
    }

    /// What other windows read. Every path that changes what this window is waiting on has to end here.
    private func publishAttention() {
        guard !didTearDown else { return }
        AttentionCenter.shared.update(
            windowID: windowID, waitingCount: attention.waitingCount, since: attention.waitingSince)
    }

    private func renderTabBar() {
        let items = activeTabIDs.enumerated().map { i, id in
            TabBarItem(
                id: id, index: i + 1,
                title: title(of: id),
                isActive: id == activeWorkspace?.activeID,
                attentionState: attention.state(tab: id).tabState)
        }
        tabBar.render(items)
        switch selection {
        case .workspace(let workspace): window.title = workspace.name
        case .host(let host): window.title = host.name
        }
        let waiting = workspaces.filter { attention.state(tabs: $0.tabIDs) == .waiting }.map(\.id)
        sidebar.render(
            order: order, workspaces: workspaces, active: activeWorkspace, activeHost: selection.host,
            waiting: Set(waiting))
        renderAgents()
        for (id, card) in attentionCards {
            cardTitles[id].map { card.setTitle($0()) }
            card.refreshShortcuts()
        }
    }

    private func switchShortcut(for id: TabID) -> String {
        guard let workspace = workspace(of: id) else { return "" }
        guard workspace === activeWorkspace else {
            guard workspace.activeID == id,
                let number = order.position(of: workspace.id).map({ $0 + 1 }), number <= 9
            else { return "" }
            return CommandCatalog.spec(for: .selectWorkspace(number)).shortcut
        }
        guard let index = workspace.tabIDs.firstIndex(of: id).map({ $0 + 1 }), index <= 9 else { return "" }
        return CommandCatalog.spec(for: .selectTab(index)).shortcut
    }

    private func renderDock() {
        let overlay = activeController?.overlayState ?? OverlayState()
        dock.render(
            overlay: overlay, floatID: floats.activeID,
            tab: activeWorkspace?.activeID,
            isLiveInBackground: floats.isLiveInBackground, isFloatBusy: floats.isBusy,
            drawerAttention: { [weak self] edge in self?.drawerAttention(edge) ?? .idle },
            floatAttention: { [weak self] id in
                self?.floats.surfaceID(id).map { self?.attention.state(of: $0) ?? .idle } ?? .idle
            })
        lastBusyDots = busyDots()
        sidebar.setOpenModal(palette: modal?.kind == .commandPalette, settings: modal?.kind == .settings)
    }

    private func drawerAttention(_ edge: DrawerEdge) -> SurfaceAttention {
        guard let ids = activeController?.drawerSurfaceIDs else { return .idle }
        guard let id = edge == .bottom ? ids.bottom : ids.right else { return .idle }
        return attention.state(of: id)
    }

    private func bindFirstControllerIfNeeded() {
        guard let workspace = activeWorkspace, let firstID = workspace.activeID, let c = workspace.controller(firstID)
        else { return }
        wire(c, id: firstID)
    }

    // Ends capture and modes unconditionally: both handlers are app-wide and would strand every other window.
    private func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        if let attentionObserver { NotificationCenter.default.removeObserver(attentionObserver) }
        attentionObserver = nil
        AttentionCenter.shared.forget(windowID: windowID)
        pendingModal = nil
        cancelConfirm()
        keybindCapturer?.endCapture()
        endModes()
        titlePoll?.invalidate()
        titlePoll = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let hostStatusObserver { NotificationCenter.default.removeObserver(hostStatusObserver) }
        hostStatusObserver = nil
        floats.shutdown()
        sidebar.shutdown()
        for workspace in workspaces { workspace.shutdown() }
        onClosed?()
    }
}

extension WindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard windowIsRunning else { return true }
        requestCloseWindow()
        return false
    }

    func windowWillClose(_ notification: Notification) { tearDown() }

    func windowDidResize(_ notification: Notification) { yieldSidebarIfNarrow() }

    func windowDidResignKey(_ notification: Notification) {
        windowIsKey = false
        syncWindowFocus()
        endModes()
        sidebar.edgeReveal.recheck()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        windowIsKey = true
        syncWindowFocus()
        sidebar.edgeReveal.recheck()
        sidebar.refreshBranches()
        answerPanesInView()
        answerFocusedAgent()
    }

    // Coming back looks at every pane in view, not only the focused one.
    private func answerPanesInView() {
        guard Self.isPresent(window) else { return }
        if let active = activeWorkspace?.activeID { attention.visit(active) { isSeen($0, in: active) } }
        for surface in agents.agents.keys where attention.agentWait(of: surface) == .turnEnd {
            guard let tab = tab(of: surface), isSeen(surface, in: tab) else { continue }
            attention.markSeen(surface)
        }
        for id in attentionCards.keys where isSeen(cardSurfaces[id], in: id) {
            cardSurfaces[id].map { attention.markSeen($0) }
            takeDownCard(id)
        }
    }

    // Quit never fires `windowWillClose`, so without this every shell is orphaned.
    func tearDownForQuit() { tearDown() }
}
