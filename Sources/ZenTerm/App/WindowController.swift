import AgentSetup
import AppKit
import AppLog
import ControlProtocol
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
    // A tab's notice answers one surface, which may be a drawer or a float, and stands whether or not its card shows.
    private var noticeSurfaces: [TabID: SurfaceID?] = [:]
    private var cardTitles: [TabID: () -> String] = [:]
    private let attention = AttentionStore()
    private let agents = AgentRoster()
    private let agentStates = AgentStateTracker()
    private let firstTasks: FirstTaskDelivery
    private let taskPickups = TaskPickups()
    private(set) var launchedPaneExits = LaunchedPaneExits()
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
            host: container, below: modal?.overlay ?? confirmCard, topInset: Self.toastTopInset,
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
    private var processBusy = BusyFallWatch()
    private var exitedProcesses: Set<SurfaceID> = []
    private var listedProcesses: [SurfaceID: ProcessIcon] = [:]
    private var helpersReported: Set<SurfaceID> = []
    private var blocksParentsAnswered: Set<SurfaceID> = []

    func showFontSize(_ text: String) {
        if let card = fontSizeCard {
            card.update(text: text)
            toasts.bringForward(card: card)
        } else {
            let card = FontSizeCard(text: text)
            fontSizeCard = card
            toasts.present(card: card)
        }
        fontSizeDismissal?.cancel()
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissFontSizeCard() }
        fontSizeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Linger.readout, execute: dismissal)
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
            restoreFocus: { [weak self] in self?.focusActive() },
            currentTabID: { [weak self] in self?.activeWorkspace?.activeID },
            startShell: { [weak self] surface, id, launch in
                Self.surfaceStart(over: self?.activeWorkspace?.connection)(surface, id, launch)
            })
        controller.onStateChanged = { [weak self] in self?.renderDock() }
        controller.onFocusChanged = { [weak self] in self?.syncWindowFocus() }
        controller.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        controller.onProgress = { [weak self] surface, progress in
            self?.progressChanged(surface: surface, progress: progress)
        }
        controller.onProgramStatus = { [weak self] surface, status in
            self?.programStatusChanged(surface: surface, status: status)
        }
        controller.onTitle = { [weak self] surface, title in
            self?.titleChanged(surface: surface, title: title)
        }
        controller.onSurfaceRegistered = { [weak self] surface, tab in
            self?.attention.register(surface, tab: tab)
        }
        controller.onSurfaceReleased = { [weak self] surface in
            self?.workspace(holding: surface)?.connection?.release([surface])
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

    // Always laid out, so a float pane opened in a tab that is not showing sizes to the card it will show in.
    private let floatArea = NSLayoutGuide()

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
    // What each tab last showed, so the title poll re-renders when a program changes, not on every tick.
    private var tabProcesses: [TabID: ProcessIcon?] = [:]
    private let dock: ToggleDock
    private var dockTrailing: NSLayoutConstraint?
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
        case renameTab, renameWorkspace, worktreeForm, sshHostForm

        var selfToggle: KeyInterceptor.ReservedChord? {
            switch self {
            case .repoPicker: return .toggleRepoPicker
            case .commandPalette: return .toggleCommandPalette
            case .settings: return .openSettings
            case .renameWorkspace: return .renameWorkspace
            case .workspaceForm, .toolFloatForm, .reportIssue, .renameTab, .worktreeForm, .sshHostForm:
                return nil
            }
        }

        var isForm: Bool {
            switch self {
            case .repoPicker, .commandPalette, .settings: return false
            case .workspaceForm, .toolFloatForm, .reportIssue, .renameTab, .renameWorkspace, .worktreeForm,
                .sshHostForm:
                return true
            }
        }
    }
    // `tab` is the tab a card acts on, when that can be a tab other than the showing one.
    private var modal: (overlay: ModalOverlay, kind: ModalKind, tab: TabID?)?

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

    // A pane's children can sit in any window, since `pane.run` places a child wherever its `pane` is.
    var appWindows: (() -> [WindowController])?

    var revealWorkspaceInAnotherWindow: ((URL) -> Bool)?

    var revealHostInAnotherWindow: ((SSHHostID) -> Bool)?

    var hostSessionInAnyWindow: ((SSHHostID) -> SSHConnection.State?)?

    var openWorkspacesElsewhere: (() -> [RunningWorkspace])?

    var onOpenWorkspacesChanged: (() -> Void)?

    var revealWorkspaceElsewhere: ((Int, WorkspaceID) -> Bool)?

    var worktreeRemovals = WorktreeRemovalTracker()

    var paneWaits = PaneWaits()

    var paneDrafts = PaneDrafts()

    var onHelperNote: ((HelperNote) -> Void)?

    var claudeSetupOffer: ClaudeSetupOffer?

    func tabCount(atPath path: URL) -> Int {
        allTabIDs.filter { isClosedByRemoval($0, atPath: path) }.count
    }

    func closedByRemoval(atPath path: URL) -> ClosedByRemoval {
        let children = removalStakes(atPath: path)
        if children.closesWindow { return ClosedByRemoval(thisWindow: true) }
        var closed = ClosedByRemoval(stopping: children.names)
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
        return emptied == workspaces.count ? ClosedByRemoval(thisWindow: true, stopping: children.names) : closed
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

    private var confirmCard: ConfirmCard?
    private var confirmOnCancel: (() -> Void)?
    private var confirmTab: TabID?
    var isConfirmOpen: Bool { confirmCard != nil }

    // Polled because shells report cwd without OSC 7, so a `cd` sends no event.
    private var titlePoll: Timer?

    private var configObserver: NSObjectProtocol?
    private var hostStatusObserver: NSObjectProtocol?
    // Read at the change, not from the sidebar, which a disconnect's status change redraws first.
    private var hostOrder = GeneralConfig.current.sshHostAliases.map(SSHHostID.init)
    /// Raises the window holding the agent that has waited longest and lands on it. False when it has gone.

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

    private var shownFloatPaneName: String? {
        guard let shown = floats.shownPaneSurface else { return nil }
        return allTabControllers.lazy.flatMap(\.paneHandles).first { $0.surfaceID == shown }.map(Self.paneName)
    }

    private var floatBlockToasts = ToastThrottle<Bool>()

    private func toastFloatBlocked() {
        guard floatBlockToasts.allows() else { return }
        let content =
            floats.shownPaneSurface == nil
            ? ToastContent(
                variant: .info, title: "Tool Float",
                message: "\(activeFloatName ?? "This tool") is open. Close it to get back to your panes.")
            : ToastContent(
                variant: .info, title: "Float Pane",
                message: "\(shownFloatPaneName ?? "This float pane") is open. Close it to get back to your panes.")
        toasts.show(content)
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

    private func workspace(holding surface: SurfaceID) -> WorkspaceController? {
        attention.tab(of: surface).flatMap(workspace(of:))
    }

    private func controller(_ id: TabID) -> TabController? { workspace(of: id)?.controller(id) }

    private func title(of id: TabID) -> String { workspace(of: id)?.title(id) ?? "shell" }

    private func attentionTitle(of id: TabID) -> String {
        guard workspaces.count > 1, let workspace = workspace(of: id) else { return title(of: id) }
        return "\(workspace.name): \(title(of: id))"
    }

    init(
        contentRect: NSRect, initialCWD: URL?, firstTaskWindow: TimeInterval = FirstTaskDelivery.readinessWindow
    ) {
        firstTasks = FirstTaskDelivery(readinessWindow: firstTaskWindow)
        window = HostWindow(contentRect: contentRect)
        windowID = WindowController.nextWindowID
        WindowController.nextWindowID += 1
        let firstID = TabID(1)
        let firstWorkspace = WorkspaceController(
            id: WorkspaceID(raw: 1), isConfigured: false, name: nil,
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
        var onRenameWorkspace: (WorkspaceID) -> Void = { _ in }
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
            onRenameWorkspace: { onRenameWorkspace($0) }, onCloseWorkspace: { onCloseWorkspace($0) },
            onAdd: { onOpenWorkspace() })
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
        onRenameWorkspace = { [weak self] in self?.openRenameWorkspace($0) }
        sidebar.onJump = { [weak self] in self?.toggleAgentRow($0) }
        sidebar.onCloseAgent = { [weak self] in self?.requestClose(agent: $0) }
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

        hostStatusObserver = NotificationCenter.default.addObserver(
            forName: .sshHostStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderTabBar()
                self?.refreshConnectView()
            }
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
                    self.dockTrailing?.constant = -ChromeMetrics.windowGutter
                    for controller in self.allTabControllers { controller.reapplyChromeLayout() }
                    self.connectView?.reapplyChromeLayout()
                    self.reapplyFloatLayout()
                    self.reapplyModalLayout()
                    self.builtToasts?.reapplyInsets(
                        topInset: Self.toastTopInset, trailingInset: Self.toastTrailingInset)
                }
                if change.contains(.theme) {
                    TooltipPresenter.shared.dismiss()
                    LinkPreviewPresenter.shared.dismiss()
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
                    self.renderDock()
                }
                if change.contains(.toolbarButtons) {
                    self.sidebar.setHiddenButtons(GeneralConfig.current.hiddenToolbarButtons)
                    self.renderDock()
                }
                if change.contains(.sshHosts) {
                    let shownHosts = self.hostOrder
                    self.hostOrder = GeneralConfig.current.sshHostAliases.map(SSHHostID.init)
                    self.disconnectRemovedHosts()
                    self.leaveRemovedHost(shownHosts: shownHosts)
                    self.refreshConnectView()
                    self.renderTabBar()
                }
                if change.contains(.keymap) {
                    for host in self.panelHosts { host.reapplyKeymap() }
                    self.floats.reapplyKeymap()
                }
                if change.contains(.keymap) || change.contains(.floats) {
                    (self.modal?.overlay as? PaletteOverlay)?.reapplyKeymap()
                }
                if change.contains(.terminalBehavior) {
                    for host in self.panelHosts { host.reapplyTerminalBehavior() }
                    self.floats.reapplyTerminalBehavior()
                    self.connectView?.reapplyTerminalBehavior()
                }
                if change.contains(.theme) { self.reapplyThemeTrees() }
            }
        }
    }

    private var panelHosts: [PanelHostView] { allTabControllers.flatMap(\.panelHosts) }

    private func reapplyThemeTrees() {
        window.contentView?.reapplyThemeTree()
        for host in panelHosts where host.window == nil { host.reapplyThemeTree() }
        if let connectView, connectView.window == nil { connectView.reapplyThemeTree() }
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
        installFloatArea()
        sidebar.setHiddenButtons(GeneralConfig.current.hiddenToolbarButtons)
        let dockTrailing = dock.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -ChromeMetrics.windowGutter)
        self.dockTrailing = dockTrailing
        NSLayoutConstraint.activate([
            canvasHost.leadingAnchor.constraint(equalTo: sidebar.edgeAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvasHost.topAnchor.constraint(equalTo: container.topAnchor),
            canvasHost.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            dockTrailing,
            dock.centerYAnchor.constraint(equalTo: tabBar.chipBandCenterYAnchor),
            tabBar.trailingAnchor.constraint(equalTo: dock.leadingAnchor, constant: -ChromeMetrics.Spacing.s8),
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
        if activeTabIDs.contains(where: { processIcon(of: $0) != tabProcesses[$0] ?? nil }) { changed = true }
        if refreshWorkspaceNames() { changed = true }
        if changed { renderTabBar() }
        if listedProcesses.contains(where: { id, shown in terminalSurface(id).map(programIcon) != shown }) {
            renderAgents()
        }

        if busyDots() != lastBusyDots { renderDock() }
        trackAgentExits()
        checkForRemovedWorktrees()
        sidebar.refreshBranches()
    }

    private var shownWorkspaceNames: [WorkspaceID: String] = [:]

    // A session's name follows its active tab's folder, so the pickers here and in other windows re-read it.
    @discardableResult
    private func refreshWorkspaceNames() -> Bool {
        let names = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        guard names != shownWorkspaceNames else { return false }
        shownWorkspaceNames = names
        refreshOpenPicker()
        onOpenWorkspacesChanged?()
        return true
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
        onOpenWorkspacesChanged?()
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
        cwd: URL?, command: PaneProgram? = nil, config ws: Workspace? = nil, tab index: Int = 0,
        connection: SSHConnection? = nil
    ) -> TabController {
        let tab = ws?.tabs[index]
        let mainCommand = command ?? tab?.main.flatMap { $0 == "shell" ? nil : PaneProgram(command: $0) }
        let c = TabController(
            initialCWD: cwd, initialCommand: mainCommand, env: ws?.env ?? [:],
            backingScale: window.backingScaleFactor,
            isToolFloatOpen: { [weak self] in self?.floats.isOpen ?? false }, readsForeground: connection == nil,
            startSurface: Self.surfaceStart(over: connection))
        c.rightDrawerCommand = tab?.right
        c.bottomDrawerCommand = tab?.bottom
        c.pinnedTitle = tab?.name
        return c
    }

    private static func surfaceStart(over connection: SSHConnection?) -> SurfaceStart {
        guard let connection else { return startSurfaceNow }
        return { [weak connection] surface, id, launch in
            connection?.start(surface, id: id, env: launch.environment, backingScale: launch.backingScale)
        }
    }

    private func mintTabID() -> TabID { defer { nextTabID += 1 }; return TabID(nextTabID) }

    private func mintWorkspaceID() -> WorkspaceID {
        defer { nextWorkspaceID += 1 }
        return WorkspaceID(raw: nextWorkspaceID)
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
        let view = HostConnectView(
            host: host, name: GeneralConfig.current.displayName(of: host),
            status: SSHHostStatusCenter.shared.status(of: host),
            destination: SSHHostStatusCenter.shared.destination(of: host),
            onConnect: { [weak self] in self?.connect(host) },
            onFocusRequest: { [weak self] in self?.restoreFocusToActive() })
        connectView = view
        return view
    }

    private func refreshConnectView() {
        guard let connectView else { return }
        let center = SSHHostStatusCenter.shared
        connectView.setName(GeneralConfig.current.displayName(of: connectView.host))
        connectView.setStatus(center.status(of: connectView.host))
        connectView.setDestination(center.destination(of: connectView.host))
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
            window.makeFirstResponder(connectView)
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
        activeController?.setFocusBorderVisible(holdsKeyFocus && !sidebar.isRevealed)
        connectView?.setFocusBorderVisible(activeWorkspace == nil && holdsKeyFocus && !sidebar.isRevealed)
        for controller in allTabControllers {
            controller.setHoldsKeyFocus(holdsKeyFocus && controller === activeController)
        }
        floats.setHoldsKeyFocus(holdsKeyFocus)
    }

    // Below `tabBar`, so the ⌘W guard toast fired over an open float stays visible.
    private func presentWindowFloat(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .below, relativeTo: tabBar)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: floatArea.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: floatArea.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: floatArea.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: floatArea.bottomAnchor),
        ])
    }

    private func installFloatArea() {
        container.addLayoutGuide(floatArea)
        let gutter = ChromeMetrics.windowGutter
        let insets = (
            leading: floatArea.leadingAnchor.constraint(equalTo: sidebar.canvasLeadingAnchor, constant: gutter),
            trailing: floatArea.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -gutter),
            top: floatArea.topAnchor.constraint(
                equalTo: container.topAnchor, constant: ChromeMetrics.topInset),
            bottom: floatArea.bottomAnchor.constraint(
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
        closeModal()
        closeFloatForTabChange()
        select(openTab(in: workspace, cwd: cwd, command: nil), slideFrom: .fromRight)
    }

    private func openTab(in workspace: WorkspaceController, cwd: URL?, command: PaneProgram?) -> TabID {
        Log.info("tab opened", category: .tabs)
        let id = mintTabID()
        workspace.append(id)
        installController(id: id, in: workspace, cwd: cwd, command: command, config: nil)
        return id
    }

    private func installController(
        id: TabID, in workspace: WorkspaceController, cwd: URL?, command: PaneProgram? = nil, config: Workspace?,
        tab index: Int = 0
    ) {
        let c = makeController(
            cwd: cwd, command: command, config: config, tab: index, connection: workspace.connection)
        workspace.setController(c, for: id)
        wire(c, id: id)
        c.start()
        if let config {
            c.applyRecipe(config.tabs[index], focus: config.focus.tab == index ? config.focus.region : .main)
        }
        layOutUnmounted(c)
        renderTabBar()
    }

    // An unmounted tab gets no layout pass, so its programs would start on libghostty's default grid.
    private func layOutUnmounted(_ c: TabController) {
        guard c.view.window == nil, let frame = mountedCanvas?.frame else { return }
        c.view.frame = frame
        c.view.layoutSubtreeIfNeeded()
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
    private func activate(_ id: WorkspaceID, transition: MountTransition? = nil) {
        guard let workspace = workspaces.first(where: { $0.id == id }), workspace !== activeWorkspace
        else { return }
        Log.info("workspace switched", category: .tabs)
        closeModal()
        closeFloatForTabChange()
        cancelConfirm()
        let transition = transition ?? workspaceSlide(from: activeWorkspace?.id, to: id)
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
        guard case .host(let host) = selection, !GeneralConfig.current.sshHostAliases.contains(host.alias) else {
            return
        }
        let place = shownHosts.firstIndex(of: host) ?? shownHosts.count
        let nearestHost = (shownHosts[min(place + 1, shownHosts.count)...] + shownHosts[..<place].reversed())
            .lazy.compactMap { next in self.workspaces.first { $0.host == next } }.first
        let firstWorkspace = order.navigableWorkspaces.first.flatMap { id in workspaces.first { $0.id == id } }
        guard let landing = nearestHost ?? firstWorkspace else { return }
        selection = .workspace(landing)
        mount(.instant)
        if let tab = landing.activeID { visit(tab) }
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
        let hosts = GeneralConfig.current.sshHostAliases.map(SSHHostID.init).map {
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
        let overlay = RenameOverlay(
            title: "Rename Tab", current: controller.title, placeholder: controller.liveTitle,
            onSubmit: { [weak self] name in
                self?.renameTab(id, to: name)
                self?.closeModal()
            },
            onCancel: { [weak self] in self?.closeModal() })
        presentModal(overlay, kind: .renameTab, answering: id)
    }

    func renameTab(_ id: TabID, to name: String) {
        guard let workspace = workspace(of: id), let controller = workspace.controller(id) else { return }
        controller.pinnedTitle = name.isEmpty ? nil : name
        workspace.setTitle(controller.title, for: id)
        renderTabBar()
    }

    private func openRenameWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }), workspace.host == nil else { return }
        cancelConfirm()
        if modal != nil { closeModal() }
        let overlay = RenameOverlay(
            title: "Rename Workspace", current: workspace.name, placeholder: workspace.givenName,
            onSubmit: { [weak self] name in
                self?.renameWorkspace(id, to: name)
                self?.closeModal()
            },
            onCancel: { [weak self] in self?.closeModal() })
        presentModal(overlay, kind: .renameWorkspace)
    }

    @discardableResult
    func renameWorkspace(_ id: WorkspaceID, to name: String) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == id }), workspace.host == nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.pinnedName = trimmed.isEmpty ? nil : trimmed
        Log.info("workspace renamed", category: .workspace)
        renderTabBar()
        refreshOpenPicker()
        onOpenWorkspacesChanged?()
        return true
    }

    private func closeTab(_ id: TabID, dismissingModal: Bool = true) {
        guard let workspace = workspace(of: id) else { return }
        let isShowing = id == activeWorkspace?.activeID
        dismissOverlays(closing: id, isShowing: isShowing, dismissingModal: dismissingModal)
        removeTab(id, from: workspace, remounting: isShowing)
    }

    func removeTab(_ id: TabID) {
        guard let workspace = workspace(of: id) else { return }
        let isShowing = id == activeWorkspace?.activeID
        dismissOverlays(closing: id, isShowing: isShowing, dismissingModal: false)
        removeTab(id, from: workspace, remounting: isShowing)
    }

    // The showing tab takes what answers whatever tab is showing; any tab takes the card or confirm aimed at it.
    private func dismissOverlays(closing id: TabID, isShowing: Bool, dismissingModal: Bool) {
        if isShowing {
            if dismissingModal { closeModal() }
            closeFloatForTabChange()
            cancelConfirm()
        }
        if modal?.tab == id { closeModal() }
        if confirmTab == id { cancelConfirm() }
    }

    private func removeTab(_ id: TabID, from workspace: WorkspaceController, remounting: Bool) {
        Log.info("tab closed", category: .tabs)
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
        if remounting {
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
        land(at: place)
    }

    private func closeConnectScreen() {
        Log.info("connect screen closed", category: .workspace)
        guard workspaces.isEmpty else { return land(at: order.navigableWorkspaces.count) }
        presentConfirm(
            CloseWarning.prompt(closing: .lastPane(running: windowIsRunning), naming: runningNamesInWindow())
        ) { [weak self] in self?.window.close() }
    }

    private func land(at place: Int) {
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
            id: mintWorkspaceID(), isConfigured: false, name: host.alias, folder: ShellLaunch.defaultCWD,
            firstTab: tab, connection: connection)
        connection.onLoginFailed = { [weak self, weak workspace] in
            DispatchQueue.main.async { self?.loginFailed(on: host, closing: workspace) }
        }
        workspaces.append(workspace)
        installController(id: tab, in: workspace, cwd: nil, config: nil)
        activate(workspace.id, transition: .instant)
    }

    private func loginFailed(on host: SSHHostID, closing workspace: WorkspaceController?) {
        if let workspace, workspaces.contains(where: { $0 === workspace }) { closeTabs(of: workspace) { closeTab($0) } }
        toasts.show(
            ToastContent(
                variant: .warning, title: "Couldn't Connect to",
                titleTail: " \(GeneralConfig.current.displayName(of: host))", message: nil))
    }

    private func toggleToolFloat(_ id: String, in host: SSHHostID) {
        if !toggleRunningFloat(id) { toastFloatsStayLocal(on: host) }
    }

    private func togglesRunningFloat(_ chord: KeyInterceptor.ReservedChord) -> Bool {
        guard case .toggleToolFloat(let id) = chord else { return false }
        return floats.surfaceID(id) != nil && (floats.activeID == id || floatAttention(id) >= .completed)
    }

    private func toggleRunningFloat(_ id: String) -> Bool {
        guard togglesRunningFloat(.toggleToolFloat(id)), let surface = floats.surfaceID(id) else { return false }
        if floats.activeID == id { floats.close() } else { floats.reveal(surface) }
        return true
    }

    private func toastFloatsStayLocal(on host: SSHHostID) {
        toasts.show(
            ToastContent(
                variant: .info, title: "Tool Floats",
                message: "Tool floats run on this Mac, not on \(GeneralConfig.current.displayName(of: host))."))
    }

    func holdsHost(_ host: SSHHostID) -> Bool { workspaces.contains { $0.host == host } }

    func session(of host: SSHHostID) -> SSHConnection.State? {
        workspaces.first { $0.host == host }?.connection?.state
    }

    private func presentModal(_ overlay: ModalOverlay, kind: ModalKind, answering tab: TabID? = nil) {
        if let activeWorkspace, activeWorkspace.activeController == nil { return }
        captureFocusReturn()
        endModes()
        floats.cancelPendingOpen()
        pendingModal = nil
        presentWindowModal(overlay)
        modal = (overlay, kind, tab)
        sidebar.setHoverCovered(true)
        window.hoverCover = overlay
        overlay.focusInitialResponder()
        overlay.animateIn()
        renderDock()
    }

    private func closeModal() {
        pendingModal = nil
        guard let overlay = modal?.overlay else { return }
        modal = nil
        window.hoverCover = nil
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
                onNewWorkspace: { [weak self] in self?.newWorkspace(named: $0) },
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
                    workspaceCount: self?.workspaces.count ?? 0,
                    onHost: self?.selection.host != nil)
            },
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
        let card = modal?.overlay as? NewWorktreeOverlay
        card?.beginWork("Creating \(Self.branchName(of: request))")
        WorktreeCreation.start(
            request, from: target,
            onPhase: { [weak self, weak card] phase in
                guard let card, self?.isPresenting(card) == true else { return }
                card.setPhase(phase)
            },
            completion: { [weak self, weak card] result in
                guard let self else { return }
                let stillUp = card.map(self.isPresenting) ?? false
                switch result {
                case .success(let created):
                    if stillUp { self.closeModal() }
                    self.openWorkspace(created.workspace, origin: created.origin)
                    self.reportCarry(created.carry)
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
            })
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

    private func reportCarry(_ report: CarryReport) {
        let lost = report.lost
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
            let prompt = WorktreeRemovalMessage.prompt(
                for: worktree, state: WorktreeStore.state(worktree), carried: carried, closes: closes)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.modal?.overlay === picker,
                    !self.worktreeRemovals.isRemoving(worktree.path)
                else { return }
                self.confirmRemoveWorktree(picker, worktree, from: parent, prompt: prompt)
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

    private func confirmRemoveWorktree(
        _ picker: RepoPickerOverlay, _ worktree: Worktree, from parent: Workspace, prompt: ConfirmPrompt
    ) {
        let name = worktree.name
        let card = ConfirmCard(
            prompt,
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
            onOpenURL: { [weak self] url in
                guard NSWorkspace.shared.open(url) else { return "Couldn't open your browser." }
                self?.closeModal()
                return nil
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
        case "ssh-host":
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
        case .sshHosts: return "Remote hosts"
        }
    }

    #if DEBUG
        static func settingsLandingNavTitleForTesting(for scope: ConfigDiagnostic.Scope) -> String? {
            navTitle(for: landing(for: scope))
        }
    #endif

    private func openSettings(
        landing: SettingsLanding = .top, focusingSSHHost focus: SettingsSSHHostsSection.Focus? = nil
    ) {
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
        sshHostsSection.onAddHost = { [weak self] in
            self?.openSSHHostForm(.add(taken: Set(GeneralConfig.current.sshHostAliases)))
        }
        sshHostsSection.onEditHost = { [weak self] host, address in
            self?.openSSHHostForm(.edit(host, address: address))
        }
        sshHostsSection.initialFocus = focus
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
            onSubmit: { [weak self] built in
                self?.submitToolFloat(built, replacing: originalID, returnTo: returnTo)
            },
            onCancel: { [weak self] in self?.finishToolFloatForm(returnTo) },
            onDismiss: { [weak self] in
                self?.toolFormReturn = nil
                self?.closeModal()
            },
            onDelete: float.map { existing in { [weak self] in self?.deleteToolFloat(existing) } }
        )
        toolFormReturn = returnTo
        presentModal(form, kind: .toolFloatForm)
    }

    private func deleteToolFloat(_ float: ToolFloat) -> String? {
        do {
            try ConfigWriter.apply(floatRemovals: [float.id])
        } catch {
            return "Couldn't delete \(float.id) from ZenTerm's config: \(error.localizedDescription)"
        }
        AppConfig.reload()
        reopenSettingsOnTools()
        return nil
    }

    private func submitToolFloat(
        _ float: ToolFloat, replacing originalID: String?, returnTo: ToolFormReturn = .settings
    ) -> String? {
        let removals: Set<String> = (originalID.map { $0 != float.id ? [$0] : [] }) ?? []
        do {
            try ConfigWriter.apply(floatUpserts: [float], floatRemovals: removals)
        } catch {
            return "Couldn't save \(float.id) to ZenTerm's config: \(error.localizedDescription)"
        }
        AppConfig.reload()
        finishToolFloatForm(returnTo)
        return nil
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

    private func openSSHHostForm(_ mode: AddSSHHostOverlay.Mode) {
        closeModal()
        let edited: String? =
            switch mode {
            case .add: nil
            case .edit(let host, _): host.alias
            }
        let overlay = AddSSHHostOverlay(
            mode: mode,
            removal: edited.map { alias in
                AddSSHHostOverlay.Removal(
                    session: { [weak self] in self?.removalSession(of: alias) },
                    perform: { [weak self] in self?.removeSSHHost(alias) })
            },
            onSubmit: { [weak self] host in
                edited == nil ? self?.addSSHHost(host) : self?.renameSSHHost(host)
            },
            onCancel: { [weak self] in self?.reopenSettingsOnSSHHosts(focusing: edited.map { .host($0) }) },
            onDismiss: { [weak self] in self?.closeModal() })
        presentModal(overlay, kind: .sshHostForm)
    }

    private func addSSHHost(_ host: SSHHostEntry) -> String? {
        saveSSHHost(host) { try SSHHostsWriter.add(host) }
    }

    private func renameSSHHost(_ host: SSHHostEntry) -> String? {
        saveSSHHost(host) { try SSHHostsWriter.rename(host.alias, to: host.name) }
    }

    private func saveSSHHost(_ host: SSHHostEntry, _ write: () throws -> Void) -> String? {
        do {
            try write()
        } catch {
            return "Couldn't save \(host.alias) to ZenTerm's config: \(error.localizedDescription)"
        }
        AppConfig.reload()
        reopenSettingsOnSSHHosts(focusing: .host(host.alias))
        return nil
    }

    private func removalSession(of alias: String) -> SSHConnection.State? {
        let id = SSHHostID(alias: alias)
        return hostSessionInAnyWindow.map { $0(id) } ?? session(of: id)
    }

    private func removeSSHHost(_ alias: String) -> String? {
        let aliases = GeneralConfig.current.sshHostAliases
        let neighbour = aliases.firstIndex(of: alias).flatMap { index in
            aliases.indices.contains(index + 1) ? aliases[index + 1] : index > 0 ? aliases[index - 1] : nil
        }
        do {
            try SSHHostsWriter.remove(alias)
        } catch {
            return "Couldn't remove \(alias) from ZenTerm's config: \(error.localizedDescription)"
        }
        AppConfig.reload()
        reopenSettingsOnSSHHosts(focusing: neighbour.map { .host($0) } ?? .addHost)
        return nil
    }

    private func reopenSettingsOnSSHHosts(focusing focus: SettingsSSHHostsSection.Focus? = nil) {
        closeModal()
        openSettings(landing: .sshHosts, focusingSSHHost: focus)
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
                onSubmit: { [weak self] built in
                    guard let self else { return nil }
                    guard let originalTitle else { return self.submitNewWorkspace(built) }
                    return self.submitWorkspace(
                        built, replacing: originalTitle, then: onSaved.map { saved in { saved(built) } } ?? done)
                },
                onCancel: done,
                onDismiss: { [weak self] in self?.closeModal() },
                onDelete: workspace.map { existing in
                    { [weak self] in self?.deleteWorkspace(existing, then: done) }
                }
            )
            self.presentModal(form, kind: .workspaceForm)
        }
    }

    private func submitWorkspace(
        _ ws: Workspace, replacing originalTitle: String, then done: @escaping () -> Void
    ) -> String? {
        do {
            try WorkspacesWriter.update(ws, originalTitle: originalTitle)
        } catch {
            return Self.workspaceWriteFailure(error)
        }
        done()
        return nil
    }

    private static func workspaceWriteFailure(_ error: Error) -> String {
        "Couldn't write the workspaces file: \(error.localizedDescription)"
    }

    private func deleteWorkspace(_ ws: Workspace, then done: @escaping () -> Void) -> String? {
        do {
            try WorkspacesWriter.remove(title: ws.title)
        } catch {
            return Self.workspaceWriteFailure(error)
        }
        done()
        return nil
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

    private func submitNewWorkspace(_ ws: Workspace) -> String? {
        do {
            try WorkspacesWriter.append(ws)
        } catch {
            return Self.workspaceWriteFailure(error)
        }
        closeModal()
        openWorkspace(ws)
        return nil
    }

    private func runCommand(_ chord: KeyInterceptor.ReservedChord) {
        closeModal()
        handle(chord)
    }

    // Ends modes first, or a mode swallows the Return and Esc that answer the confirm.
    func presentConfirm(
        _ prompt: ConfirmPrompt, answering tab: TabID? = nil, onConfirm: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        cancelConfirm()
        // After the card closes, not before: closing it is what hands focus back to the row it was opened from.
        closeModal()
        endModes()
        if sidebar.hasFocus { focusReturn = sidebar.focusedStop ?? focusReturn }
        confirmOnCancel = onCancel
        confirmTab = tab
        let card = ConfirmCard(
            prompt, onCancel: { [weak self] in self?.cancelConfirm() },
            onConfirm: { [weak self] in
                guard self?.confirmCard != nil else { return }
                self?.tearDownConfirm()
                onConfirm()
            })
        confirmCard = card
        presentWindowModal(card)
        sidebar.setHoverCovered(true)
        window.hoverCover = card
        card.focusInitialResponder()
        card.animateIn()
        renderDock()
    }

    private func cancelConfirm() {
        guard confirmCard != nil else { return }
        let onCancel = confirmOnCancel
        tearDownConfirm()
        onCancel?()
    }

    private func tearDownConfirm() {
        guard let card = confirmCard else { return }
        confirmCard = nil
        confirmOnCancel = nil
        confirmTab = nil
        window.hoverCover = nil
        sidebar.setHoverCovered(false)
        if modal == nil { modalGutter = nil }
        card.animateOut { card.removeFromSuperview() }
        returnFocusAfterOverlay()
        sidebar.edgeReveal.recheck()
        renderDock()
    }

    private func openWorkspace(at path: URL) -> WorkspaceController? {
        let target = path.standardizedFileURL.path
        return workspaces.first { $0.isConfigured && $0.folder.standardizedFileURL.path == target }
    }

    func holdsWorkspace(at path: URL) -> Bool { openWorkspace(at: path) != nil }

    func configuredWorkspaceID(at path: URL) -> WorkspaceID? { openWorkspace(at: path)?.id }

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
                    isWorktree: true, removedWorktreeName: workspace.isWorktreeRemoved ? workspace.origin?.name : nil,
                    pinnedName: workspace.pinnedName)
            case .ghost(let parent):
                return RunningWorkspace(
                    window: windowID, id: nil, name: parent.title, folder: parent.path, isWorktree: false,
                    removedWorktreeName: nil)
            }
        }
    }

    func listing() -> ListResult.Window {
        let order = order
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let hosts = order.hosts.compactMap { host in workspaces.first { $0.host == host.id } }
        return ListResult.Window(
            id: ControlAddress.window(windowID), key: window.isKeyWindow,
            workspaces: (order.navigableWorkspaces.compactMap { byID[$0] } + hosts.filter(Self.isListed))
                .map(listing(of:)))
    }

    // A failed login's workspace closes on the next main turn.
    private static func isListed(_ host: WorkspaceController) -> Bool { host.connection?.state != .failed }

    private static func hostListing(of workspace: WorkspaceController) -> ListResult.Host? {
        guard let host = workspace.host, let connection = workspace.connection else { return nil }
        return ListResult.Host(alias: host.alias, state: connection.state == .connected ? .connected : .connecting)
    }

    private func listing(of workspace: WorkspaceController) -> ListResult.Workspace {
        let tabs = workspace.tabIDs.compactMap { id -> ListResult.Tab? in
            guard let tab = workspace.controller(id) else { return nil }
            return ListResult.Tab(
                id: ControlAddress.tab(window: windowID, tab: id.raw), title: title(of: id),
                active: id == workspace.activeID,
                panes: tab.paneHandles.map {
                    listing(of: $0, onHost: workspace.host != nil, tabNamed: tab.pinnedTitle != nil)
                })
        }
        let host = Self.hostListing(of: workspace)
        return ListResult.Workspace(
            title: workspace.name, folder: host == nil ? workspace.folder.path : nil, host: host,
            configured: workspace.isConfigured,
            worktree: workspace.origin.map { ListResult.Worktree(name: $0.name, parent: $0.parent.path.path) },
            active: workspace === activeWorkspace, tabs: tabs)
    }

    func runsAgent(_ pane: PaneHandle) -> Bool { liveAgent(pane.surfaceID) != nil }

    func listing(of pane: PaneHandle, in tab: TabID) -> ListResult.Pane {
        let workspace = workspace(of: tab)
        return listing(
            of: pane, onHost: workspace?.host != nil, tabNamed: workspace?.controller(tab)?.pinnedTitle != nil)
    }

    // A host pane's foreground program is the local ssh, not what runs on the host.
    private func listing(of pane: PaneHandle, onHost: Bool, tabNamed: Bool) -> ListResult.Pane {
        let agent = agents.agents[pane.surfaceID].map { agent in
            let tone = AttentionTone(
                wait: attention.agentWait(of: pane.surfaceID), working: attention.isWorking(pane.surfaceID))
            return Self.agentListing(
                name: agent.name, state: Self.agentState(tone), report: agentStates.status(of: pane.surfaceID))
        }
        return ListResult.Pane(
            token: pane.token, drawer: pane.drawer.map(Self.drawer), float: pane.location == .float ? true : nil,
            title: pane.surface.title,
            cwd: pane.cwd?.path, busy: pane.surface.isBusy,
            process: onHost ? nil : Self.processListing(of: pane.surface), agent: agent, name: pane.record.name,
            parent: pane.record.parent.flatMap { NavRegistry.shared.isLive(token: $0) ? $0 : nil },
            firstTask: pane.record.firstTask, tabNamed: tabNamed ? true : nil)
    }

    private static func processListing(of surface: TerminalSurface) -> ListResult.Process? {
        guard let group = surface.foregroundProcessGroupID,
            let program = ProcessArguments.programName(of: group)
        else { return nil }
        return ListResult.Process(pid: group, program: program)
    }

    private static func agentListing(name: String?, state: ListResult.AgentState, report: TerminalProgramStatus?)
        -> ListResult.Agent
    {
        guard let report else { return ListResult.Agent(name: name, state: state) }
        var kind: ListResult.AgentNeed?
        if case .blocked(let need) = report.state { kind = need.map(Self.agentNeed) }
        return ListResult.Agent(
            name: name, state: state, status: agentStatus(report.state), kind: kind, msg: report.message,
            title: report.title)
    }

    private static func agentStatus(_ state: TerminalProgramStatus.State) -> ListResult.AgentStatus {
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .done: return .done
        case .blocked: return .blocked
        case .failed: return .error
        }
    }

    private static func agentNeed(_ need: TerminalProgramStatus.Need) -> ListResult.AgentNeed {
        switch need {
        case .permission: return .permission
        case .question: return .question
        case .auth: return .auth
        }
    }

    private static func agentState(_ tone: AttentionTone) -> ListResult.AgentState {
        switch tone {
        case .blocked, .done: return .waiting
        case .working: return .working
        case .idle: return .idle
        }
    }

    private static func drawer(_ edge: DrawerEdge) -> ListResult.Drawer {
        switch edge {
        case .bottom: return .bottom
        case .right: return .right
        }
    }

    func pane(token: Int) -> (tab: TabID, pane: PaneHandle)? { pane { $0.token == token } }

    private func pane(surface: SurfaceID) -> PaneHandle? { pane { $0.surfaceID == surface }?.pane }

    private func pane(where matches: (PaneHandle) -> Bool) -> (tab: TabID, pane: PaneHandle)? {
        for workspace in workspaces {
            for id in workspace.tabIDs {
                if let pane = workspace.controller(id)?.paneHandles.first(where: matches) { return (id, pane) }
            }
        }
        return nil
    }

    func panes(childOf parent: Int) -> [(tab: TabID, pane: PaneHandle)] {
        workspaces.flatMap { workspace in
            workspace.tabIDs.flatMap { id in
                (workspace.controller(id)?.paneHandles ?? []).filter { $0.record.parent == parent }.map { (id, $0) }
            }
        }
    }

    func helperReported(_ surface: SurfaceID) { helpersReported.insert(surface) }

    func helperHeardFromParent(_ surface: SurfaceID) {
        helpersReported.remove(surface)
        if case .blocked = agentStates.status(of: surface)?.state { blocksParentsAnswered.insert(surface) }
    }

    // Only an agent that reports its status shows when it picks a task up.
    func noteTaskSubmitted(to pane: PaneHandle) {
        guard runsAgent(pane), let status = agentStates.status(of: pane.surfaceID), TaskPickups.isReady(status)
        else { return }
        taskPickups.submitted(to: pane.surfaceID)
    }

    func isWorking(helper pane: PaneHandle, in tab: TabID) -> Bool {
        if taskPickups.awaitsPickup(pane.surfaceID) || paneDrafts.hasQueuedTask(for: pane.surfaceID) { return true }
        let listed = listing(of: pane, in: tab)
        guard let agent = listed.agent else { return listed.busy }
        return agent.status.map { $0 == .working } ?? (agent.state == .working)
    }

    private func recordExit(_ exit: LaunchedPaneExit, in tab: TabID) {
        var exit = exit
        exit.pane = controller(tab)?.paneHandles.first { $0.token == exit.token }.map { listing(of: $0, in: tab) }
        launchedPaneExits.record(exit)
    }

    func panes(named name: String) -> [(tab: TabID, pane: PaneHandle)] {
        workspaces.flatMap { workspace in
            workspace.tabIDs.flatMap { id in
                (workspace.controller(id)?.paneHandles ?? []).filter { $0.record.name == name }.map { (id, $0) }
            }
        }
    }

    func updateRecord(pane token: Int, _ change: (inout PaneRecord) -> Void) {
        guard let (tab, _) = pane(token: token) else { return }
        controller(tab)?.updateRecord(pane: token, change)
        renderAgents()
    }

    func deliverFirstTask(_ task: String, toPane token: Int, settle: @escaping (FirstTask) -> Void) {
        guard let (_, handle) = pane(token: token) else { return settle(.held(.notReady)) }
        let surface = handle.surface
        let surfaceID = handle.surfaceID
        firstTasks.await(
            surfaceID,
            send: { [weak self, weak surface] in
                surface?.paste(task)
                surface?.submit()
                self?.taskPickups.submitted(to: surfaceID)
            },
            settle: { [weak self] outcome in
                self?.updateRecord(pane: token) { $0.firstTask = outcome }
                settle(outcome)
            })
    }

    func holdsWorkspace(_ id: WorkspaceID) -> Bool { workspaces.contains { $0.id == id } }

    func activateWorkspace(_ id: WorkspaceID) { activate(id) }

    var activeWorkspaceID: WorkspaceID? { activeWorkspace?.id }

    func activeTab(of id: WorkspaceID) -> TabID? { workspaces.first { $0.id == id }?.activeID }

    func workspaceID(of tab: TabID) -> WorkspaceID? { workspace(of: tab)?.id }

    func workspaceID(of host: SSHHostID) -> WorkspaceID? {
        workspaces.first { $0.host == host && Self.isListed($0) }?.id
    }

    func host(of id: WorkspaceID) -> SSHHostID? { workspaces.first { $0.id == id }?.host }

    func listing(of id: WorkspaceID) -> ListResult.Workspace? {
        workspaces.first { $0.id == id }.map(listing(of:))
    }

    func sessionCWD(of id: WorkspaceID) -> URL? { workspaces.first { $0.id == id }?.activeController?.sessionCWD }

    func outsideRemovedWorktree(_ cwd: URL?, in id: WorkspaceID) -> URL? {
        workspaces.first { $0.id == id }?.removedWorktree?.relocating(cwd) ?? cwd
    }

    func firstPaneToken(of tab: TabID) -> Int? { controller(tab)?.paneHandles.first?.token }

    func runsAgent(_ surface: SurfaceID) -> Bool { agents.agents[surface].map { !$0.hasExited } ?? false }

    func hasAgent(atOrAbove token: Int) -> Bool {
        var seen: Set<Int> = []
        var next: Int? = token
        while let current = next, seen.insert(current).inserted, let found = familyPane(token: current) {
            if found.window.runsAgent(found.pane.surfaceID) { return true }
            next = found.pane.record.parent
        }
        return false
    }

    private func familyPane(token: Int) -> (window: WindowController, pane: PaneHandle)? {
        for window in familyWindows {
            if let found = window.pane(token: token) { return (window, found.pane) }
        }
        return nil
    }

    func openFloatPane(in tab: TabID, running program: PaneProgram?, cwd: URL?) -> Int? {
        controller(tab)?.openFloatPane(running: program, cwd: cwd, in: floatArea.frame.size)
    }

    func openTab(in id: WorkspaceID, cwd: URL?, command: PaneProgram?) -> TabID? {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return nil }
        return openTab(in: workspace, cwd: cwd, command: command)
    }

    func openConfiguredWorkspace(_ ws: Workspace, origin: WorktreeOrigin? = nil) -> WorkspaceID {
        appendWorkspace(named: ws.title, at: ws.path, config: ws, origin: origin).id
    }

    func worktreeParentFolder(of id: WorkspaceID) -> URL? {
        workspaces.first { $0.id == id }.map { $0.origin?.parent.path ?? $0.folder }
    }

    func openUnconfiguredWorkspace(at folder: URL, named name: String? = nil) -> WorkspaceID {
        appendUnconfiguredWorkspace(at: folder, named: name).id
    }

    func closeStakes(tab id: TabID, sparingWorkOf spared: Int? = nil) -> CloseStakes? {
        guard let workspace = workspace(of: id), let tab = controller(id) else { return nil }
        if holdsAwaitingLogin(tab: id) { return loginStakes(of: workspace) }
        let children = childStakes(closing: [id], sparingWorkOf: spared)
        let closesWindow = workspace.tabIDs.count == 1 && closesWindow(closing: workspace) || children.closesWindow
        let busy = tab.paneHandles.filter { $0.surface.isBusy && $0.token != spared }
        let running = spared == nil ? isRunning(tab: id) : !busy.isEmpty || floats.hasBusyInScope(id)
        return CloseStakes(
            closesWindow: closesWindow, closesOtherWindows: children.otherWindows.count,
            isRunning: running || children.isRunning,
            panes: busy.map { listing(of: $0, onHost: workspace.host != nil, tabNamed: tab.pinnedTitle != nil) }
                + children.listings,
            floats: floats.runningTitles(scope: id) + children.floatTitles
                + (closesWindow ? floats.runningTitles(scope: nil) : []))
    }

    func closeStakes(workspace id: WorkspaceID) -> CloseStakes? {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return nil }
        if workspace.host != nil { return CloseStakes(closesWindow: false, isRunning: false, panes: [], floats: []) }
        let children = childStakes(closing: Set(workspace.tabIDs))
        let closesWindow = closesWindow(closing: workspace) || children.closesWindow
        let tabs = workspace.tabIDs.compactMap(workspace.controller)
        return CloseStakes(
            closesWindow: closesWindow, closesOtherWindows: children.otherWindows.count,
            isRunning: isRunning(workspace: workspace) || children.isRunning,
            panes: tabs.flatMap { tab in
                tab.paneHandles.filter(\.surface.isBusy).map {
                    listing(of: $0, onHost: false, tabNamed: tab.pinnedTitle != nil)
                }
            }
                + children.listings,
            floats: workspace.tabIDs.flatMap { floats.runningTitles(scope: $0) } + children.floatTitles
                + (closesWindow ? floats.runningTitles(scope: nil) : []))
    }

    func focusedPane(of tab: TabID) -> PaneHandle? {
        guard let c = controller(tab) else { return nil }
        let focused = floats.shownPaneSurface.flatMap { c.isFloatPane($0) ? $0 : nil } ?? c.focusedSurfaceID
        return c.paneHandles.first { $0.surfaceID == focused }
    }

    func splitPane(_ token: Int, in tab: TabID, axis: SplitAxis, command: PaneProgram?, cwd: URL?)
        -> PaneSplitResult?
    {
        controller(tab)?.split(pane: token, axis: axis, command: command, cwd: cwd)
    }

    func closeStakes(pane: PaneHandle, in tab: TabID, closedByItsParent: Bool = false) -> CloseStakes? {
        guard let c = controller(tab), let workspace = workspace(of: tab) else { return nil }
        if workspace.connection?.isAwaitingLogin(on: pane.surfaceID) == true { return loginStakes(of: workspace) }
        let spared = closedByItsParent ? pane.token : nil
        if c.isSinglePane, pane.location == .tree { return closeStakes(tab: tab, sparingWorkOf: spared) }
        let busy = !closedByItsParent && pane.surface.isBusy
        let children = childStakes(closing: [], panes: [pane.token], sparingWorkOf: spared)
        return CloseStakes(
            closesWindow: children.closesWindow, closesOtherWindows: children.otherWindows.count,
            isRunning: busy || children.isRunning,
            panes: (busy ? [listing(of: pane, in: tab)] : [])
                + children.listings,
            floats: children.floatTitles + (children.closesWindow ? floats.runningTitles(scope: nil) : []))
    }

    private struct FamilyTab: Hashable {
        let window: ObjectIdentifier
        let tab: TabID
    }

    private struct FamilyPane {
        let window: WindowController
        let tab: TabID
        let pane: PaneHandle

        var key: FamilyTab { FamilyTab(window: ObjectIdentifier(window), tab: tab) }
    }

    @MainActor
    private struct ChildStakes {
        let running: [FamilyPane]
        let floats: [(window: WindowController, title: String)]
        let closesWindow: Bool
        let otherWindows: [WindowController]

        var isRunning: Bool { !running.isEmpty || !floats.isEmpty }
        var floatTitles: [String] { floats.map(\.title) }
        var listings: [ListResult.Pane] { running.map { $0.window.listing(of: $0.pane, in: $0.tab) } }
        var names: [String] { names(of: running) + floatTitles }

        func names(outside window: WindowController) -> [String] {
            names(of: running.filter { $0.window !== window }) + floats.filter { $0.window !== window }.map(\.title)
        }

        func held(by window: WindowController) -> ChildStakes {
            ChildStakes(
                running: running.filter { $0.window === window }, floats: floats.filter { $0.window === window },
                closesWindow: closesWindow, otherWindows: [])
        }

        private func names(of panes: [FamilyPane]) -> [String] {
            panes.map(\.pane).map(WindowController.paneName)
        }
    }

    private var familyWindows: [WindowController] {
        let windows = appWindows?() ?? []
        return windows.contains { $0 === self } ? windows : [self] + windows
    }

    private func childStakes(closing tabs: Set<TabID>, panes: Set<Int> = [], sparingWorkOf spared: Int? = nil)
        -> ChildStakes
    {
        let closing = Set(tabs.map { FamilyTab(window: ObjectIdentifier(self), tab: $0) })
        return familyStakes(closing: closing, panes: panes, sparingWorkOf: spared)
    }

    // Every window's tabs at the path close together, and each window counts only the children it holds.
    private func removalStakes(atPath path: URL) -> ChildStakes {
        let closing = familyWindows.flatMap { window in
            window.allTabIDs.filter { window.isClosedByRemoval($0, atPath: path) }.map {
                FamilyTab(window: ObjectIdentifier(window), tab: $0)
            }
        }
        return familyStakes(closing: Set(closing), panes: [], sparingWorkOf: nil).held(by: self)
    }

    // Children close after their parent, wherever they are in any window, so the warning has to count them first.
    // A child that is its tab's last pane takes the tab, with its drawers and floats, so those count too.
    private func familyStakes(closing tabs: Set<FamilyTab>, panes: Set<Int>, sparingWorkOf spared: Int?)
        -> ChildStakes
    {
        let windows = familyWindows
        let every = windows.flatMap { window in
            window.workspaces.flatMap { workspace in
                workspace.tabIDs.flatMap { id in
                    (workspace.controller(id)?.paneHandles ?? []).map { FamilyPane(window: window, tab: id, pane: $0) }
                }
            }
        }
        var closing = panes.union(every.filter { tabs.contains($0.key) }.map(\.pane.token))
        var children: [FamilyPane] = []
        var lineage: Set<Int> = spared.map { [$0] } ?? []
        var cascadedTabs: [FamilyTab] = []
        let tabCloses = { (key: FamilyTab) in
            tabs.contains(key)
                || every.filter { $0.key == key && $0.pane.location == .tree }.allSatisfy {
                    closing.contains($0.pane.token)
                }
        }
        var grew = true
        while grew {
            grew = false
            for entry in every where !closing.contains(entry.pane.token) && Self.closesWith(entry.pane, closing) {
                closing.insert(entry.pane.token)
                children.append(entry)
                if Self.closesWith(entry.pane, lineage) { lineage.insert(entry.pane.token) }
                grew = true
            }
            for key in Set(every.map(\.key))
            where !tabs.contains(key) && !cascadedTabs.contains(key) && tabCloses(key) {
                cascadedTabs.append(key)
                for owned in every where owned.key == key && owned.pane.location != .tree {
                    closing.insert(owned.pane.token)
                    children.append(owned)
                }
                grew = true
            }
        }
        guard !children.isEmpty else {
            return ChildStakes(running: [], floats: [], closesWindow: false, otherWindows: [])
        }
        let empties = { (window: WindowController) in
            !window.workspaces.isEmpty
                && window.workspaces.allSatisfy {
                    $0.host == nil
                        && $0.tabIDs.allSatisfy { tabCloses(FamilyTab(window: ObjectIdentifier(window), tab: $0)) }
                }
        }
        let otherWindows = windows.filter { $0 !== self && empties($0) }
        let floats =
            cascadedTabs.flatMap { key in
                windows.first { ObjectIdentifier($0) == key.window }.map { window in
                    window.floats.runningTitles(scope: key.tab).map { (window: window, title: $0) }
                } ?? []
            }
            + otherWindows.flatMap { window in
                window.floats.runningTitles(scope: nil).map { (window: window, title: $0) }
            }
        return ChildStakes(
            running: children.filter { $0.pane.surface.isBusy && (spared == nil || !lineage.contains($0.pane.token)) },
            floats: floats, closesWindow: empties(self), otherWindows: otherWindows)
    }

    private static func closesWith(_ pane: PaneHandle, _ closing: Set<Int>) -> Bool {
        guard let parent = pane.record.parent, !pane.record.outlivesParent else { return false }
        return closing.contains(parent)
    }

    // Async: an agent exit arrives inside its surface callback, which closing a pane would re-enter.
    private func closeFloatsOutlivingTheirAgents() {
        guard !didTearDown else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didTearDown else { return }
            for window in self.familyWindows {
                for (tab, pane) in window.floatPanes()
                where pane.record.parent.map({ !window.hasAgent(atOrAbove: $0) }) ?? false {
                    window.removePane(pane.token, in: tab)
                }
            }
        }
    }

    private func floatPanes() -> [(tab: TabID, pane: PaneHandle)] {
        workspaces.flatMap { workspace in
            workspace.tabIDs.flatMap { id in
                (workspace.controller(id)?.paneHandles ?? []).filter { $0.location == .float }.map { (id, $0) }
            }
        }
    }

    // Async: a release lands mid-rebuild of the canvas it came from, which may hold a child too.
    private func closeChildren(of parents: [Int]) {
        guard !didTearDown else { return }
        let parents = Set(parents)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didTearDown else { return }
            let children = self.workspaces.flatMap { workspace in
                workspace.tabIDs.flatMap { id in
                    (workspace.controller(id)?.paneHandles ?? []).filter { Self.closesWith($0, parents) }.map(\.token)
                }
            }
            for token in children {
                guard let (tab, _) = self.pane(token: token) else { continue }
                self.removePane(token, in: tab)
            }
        }
    }

    private func loginStakes(of workspace: WorkspaceController) -> CloseStakes {
        CloseStakes(
            closesWindow: false, isRunning: false, panes: [], floats: [],
            login: workspace.host.map {
                CloseStakes.Login(host: GeneralConfig.current.displayName(of: $0), tabs: workspace.tabIDs.count)
            })
    }

    func removePane(_ token: Int, in tab: TabID) {
        guard let c = controller(tab) else { return }
        if c.isSinglePane, !c.isFloatPane(token: token) { return removeTab(tab) }
        c.close(pane: token)
    }

    func closeStakes(atPath path: URL) -> CloseStakes {
        let tabs = allTabIDs.filter { isClosedByRemoval($0, atPath: path) }
        let children = removalStakes(atPath: path)
        let closesWindow = closedByRemoval(atPath: path).thisWindow || children.closesWindow
        return CloseStakes(
            closesWindow: closesWindow, isRunning: tabs.contains(where: isRunning(tab:)) || children.isRunning,
            panes: tabs.flatMap { tab in
                (controller(tab)?.paneHandles ?? []).filter(\.surface.isBusy).map { listing(of: $0, in: tab) }
            } + children.listings,
            floats: tabs.flatMap { floats.runningTitles(scope: $0) } + children.floatTitles
                + (closesWindow ? floats.runningTitles(scope: nil) : []))
    }

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
        activate(appendWorkspace(named: ws.title, at: ws.path, config: ws, origin: origin).id, transition: .instant)
    }

    // The home folder, not the focused pane's: a workspace is a place, and folder identity makes two on one folder collide.
    private func newWorkspace(named name: String? = nil) {
        closeModal()
        activate(appendUnconfiguredWorkspace(at: ShellLaunch.defaultCWD, named: name).id, transition: .instant)
    }

    private func appendUnconfiguredWorkspace(at folder: URL, named name: String? = nil) -> WorkspaceController {
        appendWorkspace(named: name, at: folder, config: nil)
    }

    private func appendWorkspace(
        named name: String?, at folder: URL, config: Workspace?, origin: WorktreeOrigin? = nil
    ) -> WorkspaceController {
        Log.info("workspace opened", category: .workspace)
        let tabs = (0..<(config?.tabs.count ?? 1)).map { _ in mintTabID() }
        let group = config.map { _ in (origin?.parent.path ?? folder).standardizedFileURL.path }
        let seat = group.flatMap { group in workspaces.first { WorkspaceOrder.groupFolder(of: $0) == group }?.seat }
        let workspace = WorkspaceController(
            id: mintWorkspaceID(), isConfigured: config != nil, name: name, folder: folder, firstTab: tabs[0],
            origin: origin, seat: seat)
        workspaces.append(workspace)
        for (index, tab) in tabs.enumerated() {
            if index > 0 { workspace.append(tab) }
            installController(id: tab, in: workspace, cwd: folder, config: config, tab: index)
        }
        if let config { workspace.select(tabs[config.focus.tab]) }
        renderTabBar()
        return workspace
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
                newWorkspace(named: (modal.overlay as? RepoPickerOverlay)?.newWorkspaceName)
                return
            }
            switch chord {
            case .toggleSidebar:
                toggleSidebar()
                return
            case .toggleRepoPicker, .toggleCommandPalette, .openSettings, .toggleToolFloat, .reportIssue,
                .newTool:
                guard !modal.kind.isForm else { return }
                guard activeWorkspace != nil || chord.worksWithoutTab || togglesRunningFloat(chord) else { return }
                closingModalKind = modal.kind
                closeModal()
            default:
                return
            }
        }
        if floats.isOpen {
            switch chord {
            case .closePane:
                floats.close()
                return
            case .navLeft, .navRight, .navUp, .navDown, .prevPane, .nextPane, .focusSidebar,
                .splitVertical, .splitHorizontal,
                .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
                .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom:
                toastFloatBlocked()
                return
            case .toggleCommandPalette, .toggleRepoPicker, .openSettings, .reportIssue, .newTool,
                .renameTab, .renameWorkspace:
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
            if case .toggleToolFloat(let id) = chord {
                pendingModal = nil
                _ = toggleRunningFloat(id)
                return
            }
            switch chord {
            case .navLeft: return navigate(.left)
            case .navRight: return navigate(.right)
            case .navUp: return navigate(.up)
            case .navDown: return navigate(.down)
            case .closePane: return closeConnectScreen()
            default: break
            }
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
        case .renameWorkspace: activeWorkspace.map { openRenameWorkspace($0.id) }
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
            if let host = activeWorkspace?.host, id != ToolFloat.scratch.id { return toggleToolFloat(id, in: host) }
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
        guard sidebar.hasFocus else {
            guard let activeController else { return navigateFromConnect(direction) }
            return activeController.navigate(direction)
        }
        if direction == .right { restoreFocusToActive() } else { activeController?.toastNoNeighbor(direction) }
    }

    private var connectNoNeighborToasts = ToastThrottle<Direction>()

    // Connect is one panel with nothing beside it, so only its left edge leads anywhere: to the sidebar.
    private func navigateFromConnect(_ direction: Direction) {
        guard direction == .left, !focusSidebar(), let hint = sidebarHint(for: direction),
            connectNoNeighborToasts.allows(direction)
        else { return }
        toasts.show(TabController.noNeighborToast(direction, hint: hint))
    }

    private func sidebarHint(for direction: Direction) -> String? {
        guard direction == .left, !sidebar.isDocked else { return nil }
        let chord = CommandCatalog.spec(for: .toggleSidebar).shortcut
        return chord.isEmpty ? nil : "Press \(chord) to show the sidebar."
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

    var holdsSessions: Bool { !allTabIDs.isEmpty || !floats.allSurfaces.isEmpty }

    func selectTab(_ id: TabID) { reveal(id) }

    func clearActiveTabNotification() {
        guard let id = activeWorkspace?.activeID else { return }
        AgentNotifier.shared.clear(windowID: windowID, tabID: id)
    }

    func presentQuitConfirm(
        tabCount: Int, windowCount: Int, onQuit: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        presentConfirm(
            CloseWarning.quit(tabCount: tabCount, windowCount: windowCount), onConfirm: onQuit, onCancel: onCancel)
    }

    private func requestClosePane() {
        guard let active = activeController else { return }

        if let workspace = activeWorkspace, isAwaitingLogin(on: active.focusedSurfaceID) {
            return confirmAbandoningLogin(of: workspace, closing: active.isDrawerFocused ? .drawer : .pane)
        }
        if active.isDrawerFocused {
            guard active.focusedDrawerIsBusy else { active.closeFocusedDrawer(); return }
            presentConfirm(CloseWarning.prompt(closing: .drawer, naming: [])) { [weak self] in
                self?.activeController?.closeFocusedDrawer()
            }
            return
        }

        guard let tab = activeWorkspace?.activeID else { return }
        confirmClosing(focusedPane(of: tab), in: tab, lastPane: active.isSinglePane) { [weak self] in
            guard let self, let active = self.activeController else { return }
            if active.closeFocused() == false { self.activeWorkspace?.activeID.map { self.closeTab($0) } }
        }
    }

    private func requestClose(agent surface: SurfaceID) {
        guard let found = pane(where: { $0.surfaceID == surface }), found.pane.drawer == nil,
            let c = controller(found.tab), let workspace = workspace(of: found.tab)
        else { return }
        if workspace.connection?.isAwaitingLogin(on: surface) == true {
            return confirmAbandoningLogin(of: workspace, closing: .pane)
        }
        let lastPane = c.isSinglePane && found.pane.location == .tree
        confirmClosing(found.pane, in: found.tab, lastPane: lastPane) { [weak self] in
            guard let self, let live = self.pane(where: { $0.surfaceID == surface }), live.tab == found.tab
            else { return }
            self.removePane(live.pane.token, in: live.tab)
        }
    }

    private func confirmClosing(
        _ pane: PaneHandle?, in tab: TabID, lastPane: Bool, close: @escaping () -> Void
    ) {
        guard let workspace = workspace(of: tab) else { return }
        if lastPane, holdsAwaitingLogin(tab: tab) { return confirmAbandoningLogin(of: workspace, closing: .tab) }
        let children =
            lastPane
            ? childStakes(closing: [tab])
            : childStakes(closing: [], panes: Set([pane?.token].compactMap { $0 }))
        let closesWindow =
            lastPane && workspace.tabIDs.count == 1 && closesWindow(closing: workspace) || children.closesWindow
        let needsConfirm =
            closesWindow
            || !children.otherWindows.isEmpty
            || pane?.surface.isBusy == true
            || children.isRunning
            || (lastPane && isRunning(tab: tab))
        guard needsConfirm else { return close() }

        let subject: CloseWarning.Subject =
            closesWindow ? .lastPane(running: windowIsRunning) : (lastPane ? .tab : .pane)
        let names =
            closesWindow
            ? runningNamesInWindow() + children.names(outside: self)
            : (lastPane ? hiddenRunningNames(inTab: tab) : []) + children.names
        presentConfirm(
            CloseWarning.prompt(closing: subject, naming: names, closingOtherWindows: children.otherWindows.count),
            answering: tab, onConfirm: close)
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
        let subject = CloseWarning.Subject.login(
            host: GeneralConfig.current.displayName(of: host), closing: target)
        presentConfirm(CloseWarning.prompt(closing: subject, naming: [])) { [weak self, weak workspace] in
            guard let self, let workspace, self.workspaces.contains(where: { $0 === workspace }) else { return }
            self.abandonLogin(of: workspace)
        }
    }

    private func abandonLogin(of workspace: WorkspaceController) {
        Log.info("ssh login closed before connecting", category: .workspace)
        disconnect(workspace)
    }

    private func disconnect(_ workspace: WorkspaceController, dismissingModal: Bool = true) {
        workspace.connection?.shutdown()
        closeTabs(of: workspace) { closeTab($0, dismissingModal: dismissingModal) }
    }

    // Leaves an open card up, since a host is usually removed from inside Settings.
    private func disconnectRemovedHosts() {
        let enabled = GeneralConfig.current.sshHostAliases
        for workspace in workspaces {
            guard let host = workspace.host, !enabled.contains(host.alias) else { continue }
            Log.info("ssh host removed, so it disconnects", category: .workspace)
            disconnect(workspace, dismissingModal: false)
        }
    }

    private func requestCloseTab(_ id: TabID) {
        guard let workspace = workspace(of: id) else { return }
        if holdsAwaitingLogin(tab: id) { return confirmAbandoningLogin(of: workspace, closing: .tab) }
        let children = childStakes(closing: [id])
        let closesWindow = workspace.tabIDs.count == 1 && closesWindow(closing: workspace) || children.closesWindow
        guard closesWindow || isRunning(tab: id) || children.isRunning || !children.otherWindows.isEmpty else {
            closeTab(id)
            return
        }
        let subject: CloseWarning.Subject =
            closesWindow ? .lastTab(running: windowIsRunning) : .tab
        let names =
            closesWindow
            ? runningNamesInWindow() + children.names(outside: self) : hiddenRunningNames(inTab: id) + children.names
        presentConfirm(
            CloseWarning.prompt(closing: subject, naming: names, closingOtherWindows: children.otherWindows.count),
            answering: id
        ) { [weak self] in self?.closeTab(id) }
    }

    func requestCloseWorkspace(id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        requestCloseWorkspace(workspace)
    }

    private func requestCloseWorkspace(_ workspace: WorkspaceController) {
        if workspace.host != nil {
            Log.info("ssh host disconnected", category: .workspace)
            return disconnect(workspace)
        }
        let children = childStakes(closing: Set(workspace.tabIDs))
        let closesWindow = closesWindow(closing: workspace) || children.closesWindow
        guard closesWindow || isRunning(workspace: workspace) || children.isRunning || !children.otherWindows.isEmpty
        else {
            closeTabs(of: workspace) { closeTab($0) }
            return
        }
        let subject: CloseWarning.Subject =
            closesWindow ? .lastWorkspace(running: windowIsRunning) : .workspace(workspace.name)
        let names =
            closesWindow
            ? runningNamesInWindow() + children.names(outside: self)
            : runningTabNames(in: workspace) + children.names
        presentConfirm(
            CloseWarning.prompt(closing: subject, naming: names, closingOtherWindows: children.otherWindows.count)
        ) { [weak self] in self?.closeTabs(of: workspace) { self?.closeTab($0) } }
    }

    // A host's workspace closes back to its Connect screen, so only a lone local workspace takes the window.
    private func closesWindow(closing workspace: WorkspaceController?) -> Bool {
        workspace?.host == nil && workspaces.count == 1
    }

    func removeWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        workspace.connection?.shutdown()
        closeTabs(of: workspace) { removeTab($0) }
    }

    private func closeTabs(of workspace: WorkspaceController, closing close: (TabID) -> Void) {
        let background = workspace.tabIDs.filter { $0 != workspace.activeID }
        for id in background + [workspace.activeID].compactMap({ $0 }) { close(id) }
    }

    private func requestCloseWindow() {
        let children = childStakes(closing: Set(allTabIDs))
        guard windowIsRunning || children.isRunning || !children.otherWindows.isEmpty else {
            window.close()
            return
        }
        presentConfirm(
            CloseWarning.prompt(
                closing: .window, naming: runningNamesInWindow() + children.names(outside: self),
                closingOtherWindows: children.otherWindows.count)
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
        let floatPanes = (controller(id)?.paneHandles ?? []).filter {
            $0.location == .float && $0.surface.isBusy && $0.surfaceID != floats.shownPaneSurface
        }
        return drawers + floatPanes.map(Self.paneName) + floats.hiddenRunningTitles(scope: id)
    }

    private static func paneName(_ pane: PaneHandle) -> String {
        pane.drawer.map(drawerName) ?? pane.record.name
            ?? (pane.surface.title.isEmpty ? "pane \(pane.token)" : pane.surface.title)
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
        if let surface = presentFocusedSurface {
            paneDrafts.typed(answersPrompt(surface) ? .none : .addUnknown, into: surface)
        }
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
            self.refreshWorkspaceNames()
            self.renderAttention()
        }
        c.onLastPaneClosed = { [weak self] in self?.closeTab(id) }
        c.onLaunchedPaneExited = { [weak self] exit in
            self?.recordExit(exit, in: id)
            self?.helperExited(exit)
        }
        c.onPaneTokensReleased = { [weak self] tokens in self?.familyWindows.forEach { $0.closeChildren(of: tokens) } }
        c.floatPanePresenter = floats
        c.removedWorktree = { [weak self] in self?.workspace(of: id)?.removedWorktree }
        c.onOverlayStateChanged = { [weak self] in self?.renderDock() }
        c.onRequestToast = { [weak self] content in self?.toasts.show(content) }
        c.onPaneStartFailed = { [weak self] retry, close in
            self?.presentSurfaceFailureToast(retry: retry, close: close)
        }
        c.onFocusChanged = { [weak self, weak c] in
            guard let self, c === self.activeController else { return }
            self.cancelConfirm()
            self.endModes()
            self.answerFocusedAgent()
            self.syncWindowFocus()
        }
        c.focusPastLeftEdge = { [weak self, weak c] in
            guard let self, c === self.activeController else { return false }
            return self.focusSidebar()
        }
        c.noNeighborHint = { [weak self] direction in self?.sidebarHint(for: direction) }
        c.onSurfaceEvent = { [weak self] surface, event in self?.report(surface, event) }
        c.onProgress = { [weak self] surface, progress in
            self?.progressChanged(surface: surface, progress: progress)
        }
        c.onProgramStatus = { [weak self] surface, status in
            self?.programStatusChanged(surface: surface, status: status)
        }
        c.onTitle = { [weak self] surface, title in
            self?.titleChanged(surface: surface, title: title)
        }
        c.onSurfaceShown = { [weak self] surface in self?.surfaceShown(surface) }
        c.onSurfacesRegistered = { [weak self] ids in
            ids.forEach { self?.attention.register($0, tab: id) }
        }
        c.onSurfacesReleased = { [weak self] ids in
            ids.forEach { self?.floats.hidePane($0) }
            self?.paneWaits.panesClosed(ids)
            self?.paneDrafts.panesClosed(ids)
            self?.workspace(of: id)?.connection?.release(ids)
            ids.forEach {
                self?.firstTasks.release($0)
                self?.taskPickups.release($0)
                self?.attention.release($0)
                self?.agents.drop($0)
                self?.agentStates.drop($0)
                self?.helpersReported.remove($0)
                self?.blocksParentsAnswered.remove($0)
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

    private func helperExited(_ exit: LaunchedPaneExit) {
        guard let (_, pane) = pane(token: exit.token) else { return }
        noteHelper(pane.surfaceID, .exited(code: exit.exitCode), answering: .exited)
    }

    // The banner lands on `owner`: a hidden Scratch asking for input is usually not in the active tab.
    private func floatNotified(
        surface: SurfaceID?, _ notification: TerminalNotification, from spec: ToolFloat, owner: TabID?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let activeID = self.activeWorkspace?.activeID ?? Self.untabbedCardSlot
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
            noteStatelessNotification(surface, notification, on: id, address: address, message: message)
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
            destination: edge.map { drawerDestination($0, in: id) } ?? floatPaneDestination(surface, in: id))
    }

    // Bringing a float pane's tab forward leaves the float hidden, so Switch shows it.
    private func floatPaneDestination(_ surface: SurfaceID?, in id: TabID) -> CardDestination? {
        guard let surface, controller(id)?.isFloatPane(surface) == true else { return nil }
        return CardDestination(
            shortcut: { [weak self] in self?.switchShortcut(for: id) ?? "" },
            open: { [weak self] in self?.focus(surface, in: id) })
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
        let reportsStatus = surface.map { agentStates.status(of: $0) != nil } ?? false
        return AgentRules.notificationKind(body: notification.body, agentName: name, reportsStatus: reportsStatus)
    }

    // Its state already moved, so it carries only words a row lacks and the banner an unseen turn end still owes.
    private func noteStatelessNotification(
        _ surface: SurfaceID?, _ notification: TerminalNotification, on id: TabID, address: CardAddress,
        message: String
    ) {
        guard let surface else { return }
        identifyAgent(surface, name: notification.title.isEmpty ? nil : notification.title, source: .signal)
        if !notification.body.isEmpty, agentStates.status(of: surface) == nil {
            agents.setMessage(surface, notification.body)
        }
        if attention.agentWait(of: surface) == .turnEnd { pushBanner(for: id, address: address, message: message) }
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
        guard attention.agentWait(of: surface) == .turnEnd, !askOutranksTurnEnd(in: tab) else { return }
        presentAttentionCard(
            .waiting, for: tab, address: cardAddress(of: surface, in: tab), message: Self.turnEndMessage,
            surface: surface)
    }

    // A tab shows one card, and a finished turn is never worth more than a question whose card is up or off.
    private func askOutranksTurnEnd(in tab: TabID) -> Bool {
        guard let surface = noticeSurfaces[tab] ?? nil, attention.agentWait(of: surface) == .ask else { return false }
        return attentionCards[tab] != nil || GeneralConfig.current.attentionToast == .off
    }

    private static let blockedMessage = "Waiting for your approval."

    private static let turnEndMessage = "Finished its turn."

    private func commandFinished(surface: SurfaceID?, id: TabID, result: TerminalCommandResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.workspace(of: id) != nil else { return }
            if let surface { self.paneWaits.commandFinished(surface, exitCode: result.exitCode) }
            if let surface, self.isProcessPane(surface) { self.processFinished(surface) }
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
            if title == SSHLaunch.clearedTitle, self.liveAgent(surface) != nil,
                self.workspace(holding: surface)?.host != nil
            {
                return self.endHostAgent(surface)
            }
            var joined = false
            if !self.agents.contains(surface), let name = AgentRules.agentName(matching: title) {
                self.identifyAgent(surface, name: name, source: .signal)
                joined = true
            }
            guard self.agents.contains(surface) else {
                if self.listedProcesses[surface] != nil { self.renderAgents() }
                return
            }
            let previous = self.agentStates.title(of: surface)
            self.agentStates.noteTitle(title, of: surface)
            if self.attention.agentWait(of: surface) != nil, self.agentStates.status(of: surface) == nil,
                AgentRules.isClaudeResuming(from: previous, to: title, agentName: self.agents.agents[surface]?.name)
            {
                self.answerAgent(surface)
            }
            guard !self.deriveAgentState(surface) else { return }
            if self.agentStates.state(of: surface) == .working { self.noteTitleMessage(surface) }
            let name = self.agents.agents[surface]?.name
            if joined
                || AgentRules.taskTitle(fromPane: title, agentName: name)
                    != AgentRules.taskTitle(fromPane: previous, agentName: name)
            {
                self.renderAgents()
            }
        }
    }

    // The tail is the live tool name, so it moves many times inside one turn the state never leaves.
    private func noteTitleMessage(_ surface: SurfaceID) {
        guard attention.agentWait(of: surface) == nil, agentStates.status(of: surface) == nil,
            let message = AgentRules.message(
                fromTitle: agentStates.title(of: surface), agentName: agents.agents[surface]?.name),
            agents.agents[surface]?.message != message
        else { return }
        agents.setMessage(surface, message)
        renderAgents()
    }

    private func programStatusChanged(surface: SurfaceID, status: TerminalProgramStatus?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let settlesFirstTask = self.firstTasks.isAwaiting(surface)
            if let status {
                self.taskPickups.report(status, from: surface)
                self.firstTasks.report(status, from: surface)
            } else {
                self.taskPickups.release(surface)
            }
            guard self.agents.agents[surface]?.hasExited != true else { return }
            if let status {
                let name = status.app.map { AgentRules.key(for: $0) ?? $0 }
                self.identifyAgent(surface, name: name, source: .signal)
            }
            guard self.agents.contains(surface) else { return }
            let previous = self.agentStates.status(of: surface)
            self.agentStates.noteStatus(status, of: surface)
            let moved = self.deriveAgentState(surface)
            if let status { self.agents.setMessage(surface, status.message) }
            if !moved, let status, let previous, Self.asks(previous), Self.asks(status), previous != status {
                self.raiseAsk(surface)
            }
            self.renderAgents()
            let stopped = previous?.state == .working && status?.state != .working
            if Self.startsTurn(from: previous, to: status) { self.helpersReported.remove(surface) }
            let answeredByParent =
                Self.leavesBlock(from: previous, to: status)
                && self.blocksParentsAnswered.remove(surface) != nil
            if !settlesFirstTask, !answeredByParent, let change = Self.helperChange(from: previous, to: status) {
                self.noteHelper(surface, change, answering: stopped ? .stopped : nil)
            }
            if stopped { self.paneWaits.agentStopped(surface) }
        }
    }

    // Leaving a block resumes the turn the agent was in, so only a start from rest begins a new one.
    private static func startsTurn(from previous: TerminalProgramStatus?, to status: TerminalProgramStatus?) -> Bool {
        guard status?.state == .working else { return false }
        switch previous?.state {
        case nil, .idle, .done, .failed: return true
        case .working, .blocked: return false
        }
    }

    private static func leavesBlock(from previous: TerminalProgramStatus?, to status: TerminalProgramStatus?) -> Bool {
        guard case .blocked = previous?.state else { return false }
        if case .blocked = status?.state { return false }
        return true
    }

    // Entering `blocked` is its own note, so a helper that stops to ask sends one note, not two.
    private static func helperChange(from previous: TerminalProgramStatus?, to status: TerminalProgramStatus?)
        -> HelperNote.Change?
    {
        if case .blocked(let need) = status?.state {
            if case .blocked = previous?.state { return nil }
            return .blocked(need.map(agentNeed))
        }
        if case .blocked = previous?.state, status?.state == .working { return .resumed }
        guard previous?.state == .working, status?.state != .working else { return nil }
        return .stopped(status.map { agentStatus($0.state) })
    }

    // Read before the change reaches `paneWaits`, which drops the waits it answers.
    private func noteHelper(_ surface: SurfaceID, _ change: HelperNote.Change, answering reason: WaitReason?) {
        guard let pane = pane(surface: surface), let parent = pane.record.parent else { return }
        if case .stopped = change, helpersReported.contains(surface) || paneDrafts.hasQueuedTask(for: surface) {
            return
        }
        onHelperNote?(
            HelperNote(
                helper: pane.token, name: pane.record.name, parent: parent, change: change,
                answeredWaits: change == .resumed
                    ? paneWaits.callers(watching: surface)
                    : reason.map { paneWaits.callers(answeredBy: $0, on: surface) } ?? []))
    }

    private static func asks(_ status: TerminalProgramStatus) -> Bool {
        switch status.state {
        case .blocked, .failed: return true
        case .idle, .working, .done: return false
        }
    }

    @discardableResult
    private func deriveAgentState(_ surface: SurfaceID) -> Bool {
        guard let agent = agents.agents[surface] else { return false }
        let outcome = AgentStateEngine.evaluate(
            AgentRules.rules(for: agent.name), title: agentStates.title(of: surface),
            progress: agentStates.progress(of: surface), status: agentStates.status(of: surface))
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
            if attention.agentWait(of: surface) != .ask { takeDownNotice(of: surface) }
            attention.setWorking(surface, true)
            noteTitleMessage(surface)
        case .idle:
            let endedTurn = attention.isWorking(surface)
            if endedTurn { answerAgent(surface) }
            attention.setWorking(surface, false)
            if attention.agentWait(of: surface) == nil { agents.setMessage(surface, nil) }
            if endedTurn, agents.agents[surface]?.name != nil { finishTurn(surface) }
        case .blocked:
            attention.setWorking(surface, false)
            raiseAsk(surface)
        }
        renderAgents()
    }

    private func raiseAsk(_ surface: SurfaceID) {
        guard let tab = tab(of: surface) else { return }
        let seen = isSeen(surface, in: tab)
        attention.ask(surface, seen: seen)
        let status = agentStates.status(of: surface)
        let message =
            status?.message ?? status.flatMap(Self.askMessage)
            ?? AgentRules.codexAsk(fromTitle: agentStates.title(of: surface)) ?? Self.blockedMessage
        let address = cardAddress(of: surface, in: tab)
        pushBanner(for: tab, address: address, message: message)
        guard !seen else { return }
        presentAttentionCard(.waiting, for: tab, address: address, message: message, surface: surface)
    }

    private static func askMessage(_ status: TerminalProgramStatus) -> String? {
        switch status.state {
        case .failed: return "Stopped with an error."
        case .blocked(.question): return "Waiting for your answer."
        case .blocked(.auth): return "Waiting for you to sign in."
        case .blocked, .idle, .working, .done: return nil
        }
    }

    // A window float belongs to no tab, so it asks from whichever tab is showing it.
    private func tab(of surface: SurfaceID) -> TabID? {
        attention.tab(of: surface)
            ?? (floats.float(of: surface) != nil ? activeWorkspace?.activeID ?? Self.untabbedCardSlot : nil)
    }

    // Never minted: a float asking over a Connect screen has no tab, and its card still needs a key.
    private static let untabbedCardSlot = TabID(0)

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
        noticeSurfaces.updateValue(surface, forKey: id)
        guard dismissal != .off else { return }
        if let old = attentionCards[id] { toasts.dismiss(old) }
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
        if floats.shownPaneSurface == surface { return true }
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
        if let pane = floats.shownPaneSurface { return pane }
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
    func keyReachedFocus(_ event: NSEvent) {
        guard !search.isEditing, let surface = presentFocusedSurface else { return }
        let edit = answersPrompt(surface) ? .none : DraftEdit(event, composing: isComposing(surface))
        paneDrafts.typed(edit, into: surface)
        answerTypedAgent()
    }

    private func isComposing(_ surface: SurfaceID) -> Bool {
        (terminalSurface(surface)?.view as? NSTextInputClient)?.hasMarkedText() == true
    }

    // A key or paste into a blocked agent answers its prompt, so it neither starts the draft nor sends it.
    private func answersPrompt(_ surface: SurfaceID) -> Bool {
        if case .blocked = agentStates.status(of: surface)?.state { return true }
        return false
    }

    func answerTypedAgent() {
        guard !search.isEditing, let surface = presentFocusedSurface,
            attention.agentWait(of: surface) != nil, !awaitsSignalAnswer(surface)
        else { return }
        answerAgent(surface)
    }

    // An arrow key at a prompt sends nothing, so an agent that signals its own answer is never answered by a key.
    private func awaitsSignalAnswer(_ surface: SurfaceID) -> Bool {
        guard let agent = liveAgent(surface) else { return false }
        let signalsItsAnswer = AgentRules.key(for: agent.name) != nil || agentStates.status(of: surface) != nil
        return signalsItsAnswer && attention.agentWait(of: surface) == .ask
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
        identifyAgent(surface, name: name, source: .launch)
        renderAgents()
    }

    private func identifyAgent(_ surface: SurfaceID, name: String?, source: AgentRoster.Source) {
        agents.identify(surface, name: name, source: source)
        guard AgentRules.key(for: agents.agents[surface]?.name) == "claude" else { return }
        claudeSetupOffer?.claudeStarted { [weak self] in self?.showClaudeStartup($0) }
    }

    private func showClaudeStartup(_ startup: ClaudeCodeSetup.Startup) {
        switch startup {
        case .notInstalled:
            presentClaudeSetupPrompt(
                title: "Teach Claude Code to use zen?",
                message: Self.claudeSetupOfferMessage(in: ClaudeCodeSetup.folderName),
                confirm: "Set up", decline: "Don't ask again",
                onConfirmed: { [weak self] in self?.showClaudeSetupResult($0) },
                onDeclined: { [weak self] in self?.claudeSetupOffer?.declineForGood() })
        case .edited(let version):
            presentClaudeSetupPrompt(
                title: "Update zen for Claude Code?", message: Self.claudeUpdateOfferMessage,
                confirm: "Update", decline: "Skip this version",
                onConfirmed: { [weak self] in self?.showClaudeUpdateResult($0) },
                onDeclined: { [weak self] in self?.claudeSetupOffer?.skipUpdate(to: version) })
        case .updated:
            showClaudeUpdated()
        case .updateFailed(let error):
            showClaudeSetupFailure(error, title: Self.claudeUpdateFailedTitle)
        case .current:
            break
        }
    }

    private func presentClaudeSetupPrompt(
        title: String, message: String, confirm: String, decline: String,
        onConfirmed: @escaping (Result<ClaudeSetup.State, ClaudeSetupError>) -> Void,
        onDeclined: @escaping () -> Void
    ) {
        weak var toast: ToastView?
        let actions = [
            ToastAction(title: confirm, kind: .primary) { [weak self] in
                toast.map { self?.toasts.dismiss($0) }
                ClaudeCodeSetup.refresh(applying: .install, completion: onConfirmed)
            },
            ToastAction(title: decline, kind: .cancel) { [weak self] in
                toast.map { self?.toasts.dismiss($0) }
                onDeclined()
            },
        ]
        let shown = toasts.showSticky(
            ToastContent(variant: .info, title: title, message: message), actions: actions, showsClose: true)
        shown.onClose = { [weak self, weak shown] in shown.map { self?.toasts.dismiss($0) } }
        toast = shown
    }

    // Two lines because each has to fit `ToastView.messageMaxWidth` on its own.
    static func claudeSetupOfferMessage(in folder: String) -> String {
        "The zen skill and a session hook,\nin \(folder)"
    }

    // Two lines because each has to fit `ToastView.messageMaxWidth` on its own.
    static let claudeUpdateOfferMessage = "Your zen setup has changes, and\nupdating replaces them."

    private func showClaudeSetupResult(_ result: Result<ClaudeSetup.State, ClaudeSetupError>) {
        switch result {
        case .success:
            toasts.show(
                ToastContent(
                    variant: .positive, title: "Claude Code can use zen",
                    message: "New Claude sessions load the zen skill."))
        case .failure(let error):
            showClaudeSetupFailure(error, title: "Couldn't set up Claude Code")
        }
    }

    private func showClaudeUpdateResult(_ result: Result<ClaudeSetup.State, ClaudeSetupError>) {
        switch result {
        case .success: showClaudeUpdated()
        case .failure(let error): showClaudeSetupFailure(error, title: Self.claudeUpdateFailedTitle)
        }
    }

    static let claudeUpdateFailedTitle = "Couldn't update zen"

    private func showClaudeUpdated() {
        toasts.show(
            ToastContent(variant: .info, title: "Updated zen for Claude Code", message: "New Claude sessions load it."))
    }

    private func showClaudeSetupFailure(_ error: ClaudeSetupError, title: String) {
        let content = ToastContent(variant: .warning, title: title, message: error.message)
        let shown = toasts.showSticky(content, actions: [], showsClose: true)
        shown.onClose = { [weak self, weak shown] in shown.map { self?.toasts.dismiss($0) } }
    }

    private func agentSignalled(_ surface: SurfaceID, name: String, message: String?) {
        identifyAgent(surface, name: name.isEmpty ? nil : name, source: .signal)
        agents.setMessage(surface, message)
    }

    // Only a named agent's crash asks; any other exit lands as a command finishing.
    private func agentExited(_ surface: SurfaceID, in id: TabID, result: TerminalCommandResult) -> Bool {
        guard let agent = agents.agents[surface] else { return false }
        let message = Self.commandResultMessage(result)
        exitsAwaitingResult.remove(surface)
        taskPickups.release(surface)
        agents.markExited(surface, message: message)
        let crashed = agent.name != nil && Self.isCrash(result)
        if crashed {
            let seen = isSeen(surface, in: id)
            takeDownTurnEndNotice(of: surface)
            attention.endCrashedAgent(surface, seen: seen)
            agentStates.drop(surface)
            if !seen { raiseAskCard(surface, in: id, message: message) }
        } else {
            endAgent(surface)
        }
        renderAgents()
        closeFloatsOutlivingTheirAgents()
        return crashed
    }

    private static func isCrash(_ result: TerminalCommandResult) -> Bool {
        result.exitCode.map { $0 != 0 && !deliberateStopCodes.contains($0) } ?? false
    }

    private func endAgent(_ surface: SurfaceID) {
        takeDownTurnEndNotice(of: surface)
        attention.endAgent(surface)
        agentStates.drop(surface)
    }

    // A host sends no command result, so an agent clearing its title on the way out is its only exit.
    private func endHostAgent(_ surface: SurfaceID) {
        endAgent(surface)
        agents.drop(surface)
        renderAgents()
        closeFloatsOutlivingTheirAgents()
    }

    private func takeDownTurnEndNotice(of surface: SurfaceID) {
        if attention.agentWait(of: surface) == .turnEnd { takeDownNotice(of: surface) }
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
        let processesExited = trackProcessExits()
        if !settling.isEmpty || agents.agents != before || processesExited { renderAgents() }
        if !exitsAwaitingResult.isEmpty { closeFloatsOutlivingTheirAgents() }
    }

    // Unlisted too: a pane with no agent above it can gain one later, and must not return as live.
    private func isProcessPane(_ surface: SurfaceID) -> Bool {
        agents.agents[surface] == nil && panesBySurface()[surface]?.record.parent != nil
    }

    private func processFinished(_ surface: SurfaceID) {
        exitedProcesses.insert(surface)
        renderAgents()
    }

    private func trackProcessExits() -> Bool {
        let parented = panesBySurface().values.filter { $0.record.parent != nil }
        let ids = Set(parented.map(\.surfaceID))
        processBusy.keep(only: ids)
        exitedProcesses.formIntersection(ids)
        let fell = parented.filter {
            agents.agents[$0.surfaceID] == nil && processBusy.fell($0.surfaceID, isBusy: $0.surface.isBusy)
        }
        exitedProcesses.formUnion(fell.map(\.surfaceID))
        return !fell.isEmpty
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
            exitedProcesses.insert(id)
        }
        let items = agentItems()
        listedProcesses = Dictionary(uniqueKeysWithValues: items.filter { !$0.showsState }.map { ($0.id, $0.process) })
        sidebar.renderAgents(items)
        renderTabChips(agents: items)
    }

    private func agentItems() -> [SidebarAgentItem] {
        let panes = panesBySurface()
        let agentRows = agents.agents.compactMap { id, agent -> AgentFamilies.Member? in
            guard let place = agentPlace(id) else { return nil }
            let wait = attention.agentWait(of: id)
            let state = AttentionTone(wait: wait, working: attention.isWorking(id))
            let message = wait == .turnEnd ? Self.turnEndMessage : agent.message
            let paneTitle =
                agent.hasExited ? nil : AgentRules.taskTitle(fromPane: agentStates.title(of: id), agentName: agent.name)
            let title = agentStates.status(of: id)?.title ?? paneTitle ?? agent.name ?? AgentRoster.unnamed
            let name = agent.name.flatMap { $0.isEmpty ? nil : $0 }
            let process = name.map(ProcessIcon.forAgent) ?? .unknownAgent
            var item = SidebarAgentItem(
                id: id, state: state, summary: title,
                detail: Self.agentDetail(name: name, title: title, process: process, place: place.name),
                message: message)
            item.process = process
            let pane = panes[id]
            item.canClose = pane.map { $0.drawer == nil } ?? false
            return AgentFamilies.Member(
                item: item, since: attention.agentSince(of: id), position: place.position, token: pane?.token,
                parent: pane?.record.parent, isAgent: true)
        }
        let processRows = panes.values.compactMap { pane -> AgentFamilies.Member? in
            guard pane.record.parent != nil, agents.agents[pane.surfaceID] == nil,
                pane.location == .float || !exitedProcesses.contains(pane.surfaceID),
                let place = agentPlace(pane.surfaceID)
            else { return nil }
            let title = pane.record.name ?? (pane.surface.title.isEmpty ? Self.unnamedProcess : pane.surface.title)
            var item = SidebarAgentItem(
                id: pane.surfaceID, state: .idle, summary: title, detail: place.name, message: nil)
            item.process = programIcon(of: pane.surface)
            item.canClose = pane.drawer == nil
            return AgentFamilies.Member(
                item: item, since: nil, position: place.position, token: pane.token, parent: pane.record.parent,
                isAgent: false)
        }
        let parents = Dictionary(
            panes.values.compactMap { pane in pane.record.parent.map { (pane.token, $0) } },
            uniquingKeysWith: { first, _ in first })
        return AgentFamilies.arrange(agentRows + processRows, parents: parents)
    }

    private static let unnamedProcess = "process"

    // The generic chip cannot say which agent it is, so its name stays in words unless the title already is it.
    private static func agentDetail(name: String?, title: String, process: ProcessIcon, place: String) -> String {
        guard let name, process == .unknownAgent, name != title else { return place }
        return "\(name) · \(place)"
    }

    private func panesBySurface() -> [SurfaceID: PaneHandle] {
        var panes: [SurfaceID: PaneHandle] = [:]
        for workspace in workspaces {
            for tab in workspace.tabIDs {
                for pane in workspace.controller(tab)?.paneHandles ?? [] {
                    panes[pane.surfaceID] = pane
                }
            }
        }
        return panes
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
        let waiting = agentItems().filter(\.state.isWaiting)
        guard !waiting.isEmpty else { return toastNothingWaiting() }
        let current = waiting.firstIndex { $0.id == focusedSurface }
        let next = waiting[((current ?? -1) + 1) % waiting.count]
        Log.info("jump to waiting agent", category: .workspace)
        jumpToAgent(next.id)
    }

    private func toastNothingWaiting() {
        let elsewhere = AttentionCenter.shared.blockedCount(excluding: windowID) > 0
        toasts.show(
            ToastContent(
                variant: .info,
                title: elsewhere ? "Waiting in another window" : "Nothing is waiting",
                message: elsewhere
                    ? "An agent is waiting in another window."
                    : "No agent in this window is asking for you.\nThe sidebar lists the ones that are."))
    }

    private func toggleAgentRow(_ surface: SurfaceID) {
        if floats.shownPaneSurface == surface { return floats.hidePane(surface) }
        jumpToAgent(surface)
    }

    private func jumpToAgent(_ surface: SurfaceID) {
        if let float = floats.float(of: surface) {
            float.tab.map { reveal($0) }
            pendingModal = nil
            floats.reveal(surface)
        } else if let tab = attention.tab(of: surface) {
            focus(surface, in: tab)
        }
        answerFocusedAgent()
    }

    func focus(_ surface: SurfaceID, in tab: TabID) {
        reveal(tab)
        if let c = controller(tab), c.isFloatPane(surface), let view = c.surface(surface) {
            return floats.showPane(view, id: surface, tab: tab)
        }
        if floats.isOpen { closeFloatForTabChange() }
        controller(tab)?.focus(surface: surface)
    }

    /// Answers whatever `surface` asked now that it is on screen, and takes down the card it raised.
    private func surfaceShown(_ surface: SurfaceID) {
        attention.markSeen(surface)
        answerFocusedAgent()
        takeDownNotice(of: surface)
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
        cardTitles[id] = title
        toast.onClose = { [weak self] in self?.answer(id, surface: surface) }
        toast.onDismissed = { [weak self, weak toast] in
            guard let self, let toast, self.attentionCards[id] === toast else { return }
            self.attentionCards[id] = nil
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

    func pollTitlesForTesting() { refreshTitlesFromCWD() }

    func presentModalForTesting(_ overlay: ModalOverlay) { presentModal(overlay, kind: .workspaceForm) }

    func closeModalForTesting() { closeModal() }

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

    func attentionStateForTesting(tabIndex: Int) -> SurfaceAttention? {
        guard activeTabIDs.indices.contains(tabIndex) else { return nil }
        let state = attention.state(tab: activeTabIDs[tabIndex])
        return state > .working ? state : nil
    }

    func notifyProgramStatusForTesting(tabIndex: Int, status: TerminalProgramStatus?) {
        guard activeTabIDs.indices.contains(tabIndex),
            let surface = controller(activeTabIDs[tabIndex])?.focusedSurfaceID
        else { return }
        programStatusChanged(surface: surface, status: status)
    }

    func notifyProgressForTesting(tabIndex: Int, progress: TerminalProgress?) {
        guard activeTabIDs.indices.contains(tabIndex),
            let surface = controller(activeTabIDs[tabIndex])?.focusedSurfaceID
        else { return }
        progressChanged(surface: surface, progress: progress)
    }

    var windowAttentionForTesting: SurfaceAttention { attention.windowState }

    func drawerAttentionForTesting(_ edge: DrawerEdge) -> SurfaceAttention { drawerAttention(edge) }

    func floatAttentionForTesting(_ id: String) -> SurfaceAttention { floatAttention(id) }

    func surfaceAttentionForTesting(_ id: SurfaceID) -> SurfaceAttention { attention.state(of: id) }

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

    func agentNameForTesting(_ surface: SurfaceID) -> String? { agents.agents[surface]?.name }

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
        takeDownNotice(id)
    }

    /// Answers what the tab shows on arrival; a closed drawer or Scratch keeps its ask and card.
    private func visit(_ id: TabID) {
        attention.visit(id) { isOnScreen($0, in: id) }
        answerFocusedAgent()
        if isOnScreen(noticeSurfaces[id] ?? nil, in: id) { takeDownNotice(id) }
    }

    private func takeDownNotice(of surface: SurfaceID) {
        guard let id = noticeSurfaces.first(where: { $0.value == surface })?.key else { return }
        takeDownNotice(id)
    }

    private func takeDownNotice(_ id: TabID) {
        noticeSurfaces[id] = nil
        cardTitles[id] = nil
        if let toast = attentionCards.removeValue(forKey: id) { toasts.dismiss(toast) }
        AgentNotifier.shared.clear(windowID: windowID, tabID: id)
    }

    private func renderAttention() {
        renderTabBar()
        renderDock()
        publishAttention()
    }

    /// What other windows read. Every path that changes what this window is waiting on has to end here.
    private func publishAttention() {
        guard !didTearDown else { return }
        AttentionCenter.shared.update(windowID: windowID, blockedCount: attention.blockedCount)
    }

    // A tab shows what its agents' rows show, so it reads the same items, after their rows.
    private func renderTabChips(agents: [SidebarAgentItem]) {
        let tones = Dictionary(grouping: agents) { attention.tab(of: $0.id) }.mapValues { Set($0.map(\.state)) }
        tabProcesses = Dictionary(uniqueKeysWithValues: activeTabIDs.map { ($0, processIcon(of: $0)) })
        let items = activeTabIDs.enumerated().map { i, id in
            TabBarItem(
                id: id, index: i + 1,
                title: title(of: id),
                isActive: id == activeWorkspace?.activeID,
                indicator: Self.indicator(for: tones[id] ?? []),
                process: tabProcesses[id] ?? nil)
        }
        tabBar.render(items)
    }

    // An agent by its own name, since some run under a runtime (`gemini` is `node`); anything else by its program.
    private func processIcon(of id: TabID) -> ProcessIcon? {
        guard let controller = workspace(of: id)?.controller(id), let surfaceID = controller.focusedPaneSurfaceID,
            let surface = controller.surface(surfaceID)
        else { return nil }
        if let agent = agents.agents[surfaceID], !agent.hasExited, let name = agent.name {
            return ProcessIcon.forAgent(name)
        }
        return programIcon(of: surface)
    }

    // Unreadable arguments are a program that runs, never the resting shell.
    private func programIcon(of surface: TerminalSurface) -> ProcessIcon {
        guard let group = surface.foregroundProcessGroupID else { return .shell }
        return ProcessArguments.arguments(of: group).map(ProcessIcon.forCommand) ?? .unknown
    }

    private static func indicator(for tones: Set<AttentionTone>) -> TabChip.Indicator? {
        if tones.contains(.blocked) { return .dot(.blocked) }
        if tones.contains(.done) { return .dot(.done) }
        return tones.contains(.working) ? .spinner : nil
    }

    private func renderTabBar() {
        switch selection {
        case .workspace(let workspace): window.title = workspace.name
        case .host(let host): window.title = GeneralConfig.current.displayName(of: host)
        }
        sidebar.render(order: order, workspaces: workspaces, active: activeWorkspace, activeHost: selection.host)
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
        dock.setHiddenButtons(isOnConnect ? Set(ToolbarButton.allCases) : GeneralConfig.current.hiddenToolbarButtons)
        dock.render(
            overlay: overlay, floatID: floats.activeID,
            tab: activeWorkspace?.activeID,
            isLiveInBackground: floats.isLiveInBackground, isFloatBusy: floats.isBusy,
            drawerAttention: { [weak self] edge in self?.drawerAttention(edge) ?? .idle },
            floatAttention: { [weak self] id in self?.floatAttention(id) ?? .idle },
            showsToolFloat: { [weak self] _ in self?.showsToolFloats ?? true })
        lastBusyDots = busyDots()
        sidebar.setOpenModal(palette: modal?.kind == .commandPalette, settings: modal?.kind == .settings)
    }

    private func floatAttention(_ id: String) -> SurfaceAttention {
        floats.surfaceID(id).map(attention.state(of:)) ?? .idle
    }

    private var isOnConnect: Bool { activeWorkspace == nil }

    // A host's floats run on this Mac, so a host shows none; one that needs you asks through its card.
    private var showsToolFloats: Bool { selection.host == nil }

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
        let children = childStakes(closing: Set(allTabIDs))
        guard windowIsRunning || children.isRunning || !children.otherWindows.isEmpty else { return true }
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
        for (id, surface) in noticeSurfaces where isSeen(surface, in: id) {
            surface.map { attention.markSeen($0) }
            takeDownNotice(id)
        }
    }

    // Quit never fires `windowWillClose`, so without this every shell is orphaned.
    func tearDownForQuit() { tearDown() }
}
