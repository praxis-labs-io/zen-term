import AppKit
import PaneKit
import TerminalKit

enum DrawerEdge { case bottom, right }

enum ZoomedPanel: Equatable { case pane, bottomDrawer, rightDrawer }

struct OverlayState: Equatable {
    var isBottomOpen = false
    var isRightOpen = false
    var zoomed: ZoomedPanel?
    var bottomBusy = false
    var rightBusy = false
}

final class TabController: NSObject {
    let view = NSView()
    // Layer-backed so floats added into it later render their drop shadows.
    private let content = NSView()
    private let paneCanvas: PaneCanvasController
    private let canvas: NSView

    private static var bottomDrawerFraction: CGFloat { GeneralConfig.current.bottomDrawerFraction }
    private static var rightDrawerFraction: CGFloat { GeneralConfig.current.rightDrawerFraction }
    private var bottomDrawerRatio = min(
        TabController.bottomDrawerFraction, TabController.maxDrawerFraction)
    private var rightDrawerRatio = min(
        TabController.rightDrawerFraction, TabController.maxDrawerFraction)
    private static var drawerResizeStep: CGFloat { GeneralConfig.current.drawerResizeStep }
    private static let minDrawerExtent: CGFloat = 160
    private static var maxDrawerFraction: CGFloat { GeneralConfig.current.maxDrawerFraction }

    private var bottomDrawerSurface: TerminalSurface?
    private var bottomDrawerPanel: PanelHostView?
    private var isBottomOpen = false { didSet { onOverlayStateChanged?() } }
    private var bottomDrawerToken: Int?
    private var bottomDrawerSurfaceID: SurfaceID?

    private var rightDrawerSurface: TerminalSurface?
    private var rightDrawerPanel: PanelHostView?

    var bottomDrawerPanelForTesting: PanelHostView? { bottomDrawerPanel }
    private var isRightOpen = false { didSet { onOverlayStateChanged?() } }
    private var rightDrawerToken: Int?
    private var rightDrawerSurfaceID: SurfaceID?

    private let isToolFloatOpen: () -> Bool

    private enum PanelRef: Equatable {
        case pane, bottomDrawer, rightDrawer
        var asZoomed: ZoomedPanel {
            switch self {
            case .pane: return .pane
            case .bottomDrawer: return .bottomDrawer
            case .rightDrawer: return .rightDrawer
            }
        }
    }
    private var focusedPanel: PanelRef = .pane

    private var zoomedPanel: PanelRef? { didSet { onOverlayStateChanged?() } }
    var isZoomed: Bool { zoomedPanel != nil }

    private var focusedDrawerSurface: TerminalSurface? {
        switch focusedPanel {
        case .pane: return nil
        case .bottomDrawer: return bottomDrawerSurface
        case .rightDrawer: return rightDrawerSurface
        }
    }

    var onSurfaceEvent: ((TerminalSurface, SurfaceEvent) -> Void)?

    var focusedScrollTarget: (surface: TerminalSurface, panel: PanelHostView)? {
        switch focusedPanel {
        case .pane: return paneCanvas.focusedScrollTarget
        case .bottomDrawer:
            guard let surface = bottomDrawerSurface, let panel = bottomDrawerPanel else { return nil }
            return (surface, panel)
        case .rightDrawer:
            guard let surface = rightDrawerSurface, let panel = rightDrawerPanel else { return nil }
            return (surface, panel)
        }
    }

    private var tileConstraints: [NSLayoutConstraint] = []

    private var bottomDrawerAnimationID = 0
    private var rightDrawerAnimationID = 0

    // Counted so a bottom and a right slide cannot unclip each other early.
    private var activeDrawerSlides = 0

    private var gutterConstraints: [NSLayoutConstraint] = []

    var onTitleChanged: (() -> Void)? {
        get { paneCanvas.onTitleChanged }
        set { paneCanvas.onTitleChanged = newValue }
    }
    var onLastPaneClosed: (() -> Void)? {
        get { paneCanvas.onLastPaneClosed }
        set { paneCanvas.onLastPaneClosed = newValue }
    }

    var pinnedTitle: String?
    var title: String { pinnedTitle ?? liveTitle }
    var liveTitle: String { paneCanvas.title }
    // Falls back to the pane, because nil reads downstream as "no repository".
    var focusedCWD: URL? { focusedDrawerSurface?.currentDirectory ?? paneCanvas.focusedCWD }

    // Not `focusedCWD`: removing a worktree matches the folder the tab was opened for.
    let openedCWD: URL?

    var isSinglePane: Bool { paneCanvas.paneCount == 1 }

    var allSurfaces: [TerminalSurface] {
        paneCanvas.allSurfaces + [bottomDrawerSurface, rightDrawerSurface].compactMap { $0 }
    }

    var focusedPaneIsBusy: Bool { paneCanvas.focusedPaneIsBusy }
    // `paneCanvas.focusedLeaf` stays on the last pane while a drawer holds focus, so ask the focused panel.
    var focusedPaneIsVim: Bool {
        switch focusedPanel {
        case .pane: return paneCanvas.focusedPaneIsVim
        case .bottomDrawer, .rightDrawer:
            return drawerToken(focusedPanel).map(NavRegistry.shared.isVim) ?? false
        }
    }

    var hasBusyDrawer: Bool {
        bottomDrawerSurface?.isBusy == true || rightDrawerSurface?.isBusy == true
    }

    var isDrawerFocused: Bool { focusedPanel != .pane }

    var focusedDrawerIsBusy: Bool { focusedDrawerSurface?.isBusy == true }

    var overlayState: OverlayState {
        OverlayState(
            isBottomOpen: isBottomOpen, isRightOpen: isRightOpen,
            zoomed: zoomedPanel.map(\.asZoomed),
            bottomBusy: bottomDrawerSurface?.isBusy == true,
            rightBusy: rightDrawerSurface?.isBusy == true)
    }
    var onOverlayStateChanged: (() -> Void)?

    var onRequestToast: ((ToastContent) -> Void)?

    var onPaneStartFailed: ((@escaping () -> Void, @escaping () -> Void) -> Void)?

    var onFocusChanged: (() -> Void)?

    var onNotification: ((SurfaceID, TerminalNotification) -> Void)?

    var onCommandFinished: ((SurfaceID, TerminalCommandResult) -> Void)?

    var onProgress: ((SurfaceID, TerminalProgress?) -> Void)?

    var onSurfacesRegistered: (([SurfaceID]) -> Void)?

    var onSurfacesReleased: (([SurfaceID]) -> Void)?

    var rightDrawerCommand: String?

    var bottomDrawerCommand: String?

    private let workspaceEnv: [String: String]

    private let makeSurface: () -> TerminalSurface

    init(
        initialCWD: URL?, initialCommand: String? = nil, env: [String: String] = [:],
        isToolFloatOpen: @escaping () -> Bool = { false },
        makeSurface: @escaping () -> TerminalSurface = TerminalSurfaceFactory.make
    ) {
        workspaceEnv = env
        openedCWD = initialCWD
        self.isToolFloatOpen = isToolFloatOpen
        self.makeSurface = makeSurface
        paneCanvas = PaneCanvasController(
            initialCWD: initialCWD, initialCommand: initialCommand, env: env,
            makeSurface: makeSurface)
        canvas = paneCanvas.canvasView
        canvas.translatesAutoresizingMaskIntoConstraints = false
        super.init()

        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        view.addSubview(content)
        gutterConstraints = [
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ChromeMetrics.windowGutter),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ChromeMetrics.windowGutter),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: ChromeMetrics.topInset),
        ]
        NSLayoutConstraint.activate(gutterConstraints)
        content.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        content.addSubview(canvas)
        relayoutPanels()

        paneCanvas.onFocusChanged = { [weak self] in self?.paneGainedFocus() }
        paneCanvas.onPanesRemoved = { [weak self] closed in self?.pruneNavReturn(closed: closed) }
        paneCanvas.onSocketFocus = { [weak self] dir in self?.navigate(dir) }
        paneCanvas.onZoomEnded = { [weak self] in self?.paneZoomEndedInternally() }
        paneCanvas.onNotification = { [weak self] id, n in self?.onNotification?(id, n) }
        paneCanvas.onCommandFinished = { [weak self] id, result in self?.onCommandFinished?(id, result) }
        paneCanvas.onProgress = { [weak self] id, p in self?.onProgress?(id, p) }
        paneCanvas.onSurfacesRegistered = { [weak self] ids in self?.onSurfacesRegistered?(ids) }
        paneCanvas.onSurfacesReleased = { [weak self] ids in self?.onSurfacesReleased?(ids) }
        paneCanvas.onSurfaceEvent = { [weak self] surface, event in
            self?.onSurfaceEvent?(surface, event)
        }
        paneCanvas.onSurfaceStartFailed = { [weak self] retry, close in self?.onPaneStartFailed?(retry, close) }
    }

    private func paneZoomEndedInternally() {
        if zoomedPanel == .pane {
            zoomedPanel = nil
            relayoutPanels()
        }
    }

    func start() { paneCanvas.start() }
    func split(_ axis: SplitAxis) {
        if isZoomed { toastZoomBlocked("split"); return }
        paneCanvas.split(axis)
    }
    @discardableResult func closeFocused() -> Bool {
        exitZoomIfNeeded()
        return paneCanvas.closeFocused()
    }

    func closeFocusedDrawer() {
        switch focusedPanel {
        case .pane: return
        case .bottomDrawer: closeDrawer(.bottom)
        case .rightDrawer: closeDrawer(.right)
        }
    }
    func focusActivePane() { paneCanvas.focusActivePane() }

    func applyRecipe(_ ws: Workspace) {
        if ws.right != nil, !isRightOpen { toggleRightDrawer() }
        if ws.bottom != nil, !isBottomOpen { toggleBottomDrawer() }
        switch ws.focus {
        case .right where isRightOpen: focusDrawer(.right)
        case .bottom where isBottomOpen: focusDrawer(.bottom)
        default: focusActivePane()
        }
    }

    func yieldFocusToFloat() {
        paneCanvas.setPanesFocused(false)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
    }

    func shutdown() {
        paneCanvas.shutdown()
        bottomDrawerSurface?.terminate()
        bottomDrawerSurface = nil
        unregisterDrawerToken(.bottomDrawer)
        rightDrawerSurface?.terminate()
        rightDrawerSurface = nil
        unregisterDrawerToken(.rightDrawer)
    }

    @objc func copyFromSurface(_ sender: Any?) {
        guard let surface = focusedDrawerSurface else {
            paneCanvas.copyFromSurface(sender)
            return
        }
        guard let text = surface.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func pasteToSurface(_ sender: Any?) {
        guard let surface = focusedDrawerSurface else {
            paneCanvas.pasteToSurface(sender)
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        surface.paste(text)
    }

    func toggleBottomDrawer() {
        switch zoomedPanel {
        case .pane, .bottomDrawer:
            toastZoomBlocked("toggle a drawer")
            return
        case .rightDrawer:
            switchZoomedDrawer(to: .bottom)
            return
        case nil:
            break
        }
        isBottomOpen.toggle()
        let animate = !Motion.isReduceMotionEnabled()
        if isBottomOpen {
            _ = ensureBottomDrawerPanel()
            if animate { animateBottomDrawer(opening: true) } else { relayoutPanels() }
            focusDrawer(.bottom)
        } else {
            if animate { animateBottomDrawer(opening: false) } else { relayoutPanels() }
            if focusedPanel == .bottomDrawer { restoreFocusAfterClosingDrawer(otherOpen: isRightOpen, other: .right) }
        }
    }

    private func ensureBottomDrawerPanel() -> PanelHostView {
        if let existing = bottomDrawerPanel { return existing }
        let surface = makeSurface()
        surface.delegate = self
        let token = registerDrawerToken(.bottomDrawer)
        bottomDrawerToken = token
        let surfaceID = SurfaceIDs.mint()
        bottomDrawerSurfaceID = surfaceID
        onSurfacesRegistered?([surfaceID])
        surface.start(drawerConfig(command: bottomDrawerCommand, token: token))
        bottomDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .bottom, surface: surface)
        bottomDrawerPanel = panel
        return panel
    }

    private func drawerConfig(command: String?, token: Int) -> TerminalSurfaceConfig {
        let env = NavSocketServer.env(base: workspaceEnv, token: token)
        if let command, command != "shell" {
            return ShellLaunch.program(command, cwd: focusedCWD, env: env)
        }
        return ShellLaunch.shell(cwd: focusedCWD, env: env)
    }

    private func drawerToken(_ panel: PanelRef) -> Int? {
        switch panel {
        case .bottomDrawer: return bottomDrawerToken
        case .rightDrawer: return rightDrawerToken
        case .pane: return nil
        }
    }

    private func registerDrawerToken(_ panel: PanelRef) -> Int {
        let token = NavRegistry.shared.mintToken()
        NavRegistry.shared.register(token: token) { [weak self] dir in
            guard let self, self.focusedPanel == panel, self.drawerToken(panel) == token else { return }
            self.navigate(dir)
        }
        return token
    }

    private func unregisterDrawerToken(_ panel: PanelRef) {
        switch panel {
        case .bottomDrawer:
            bottomDrawerToken.map(NavRegistry.shared.unregister)
            bottomDrawerToken = nil
            bottomDrawerSurfaceID.map { onSurfacesReleased?([$0]) }
            bottomDrawerSurfaceID = nil
        case .rightDrawer:
            rightDrawerToken.map(NavRegistry.shared.unregister)
            rightDrawerToken = nil
            rightDrawerSurfaceID.map { onSurfacesReleased?([$0]) }
            rightDrawerSurfaceID = nil
        case .pane:
            break
        }
    }

    func toggleRightDrawer() {
        switch zoomedPanel {
        case .pane, .rightDrawer:
            toastZoomBlocked("toggle a drawer")
            return
        case .bottomDrawer:
            switchZoomedDrawer(to: .right)
            return
        case nil:
            break
        }
        isRightOpen.toggle()
        let animate = !Motion.isReduceMotionEnabled()
        if isRightOpen {
            _ = ensureRightDrawerPanel()
            if animate { animateRightDrawer(opening: true) } else { relayoutPanels() }
            focusDrawer(.right)
        } else {
            if animate { animateRightDrawer(opening: false) } else { relayoutPanels() }
            if focusedPanel == .rightDrawer { restoreFocusAfterClosingDrawer(otherOpen: isBottomOpen, other: .bottom) }
        }
    }

    private func ensureRightDrawerPanel() -> PanelHostView {
        if let existing = rightDrawerPanel { return existing }
        let surface = makeSurface()
        surface.delegate = self
        let token = registerDrawerToken(.rightDrawer)
        rightDrawerToken = token
        let surfaceID = SurfaceIDs.mint()
        rightDrawerSurfaceID = surfaceID
        onSurfacesRegistered?([surfaceID])
        surface.start(drawerConfig(command: rightDrawerCommand, token: token))
        rightDrawerSurface = surface
        let panel = makeDrawerPanel(edge: .right, surface: surface)
        rightDrawerPanel = panel
        return panel
    }

    func restoreUnifiedFocus() {
        switch focusedPanel {
        case .pane: paneCanvas.focusActivePane()
        case .bottomDrawer: focusDrawer(.bottom)
        case .rightDrawer: focusDrawer(.right)
        }
    }

    private func makeDrawerPanel(edge: DrawerEdge, surface: TerminalSurface) -> PanelHostView {
        let meta =
            edge == .bottom
            ? PanelMeta(title: "Bottom drawer", action: .toggleBottomDrawer)
            : PanelMeta(title: "Right drawer", action: .toggleRightDrawer)
        let zoomMeta =
            edge == .bottom
            ? PanelMeta(title: "Bottom drawer: Focus Mode", action: .toggleZoom)
            : PanelMeta(title: "Right drawer: Focus Mode", action: .toggleZoom)
        let panel = PanelHostView(
            content: surface.view,
            meta: meta, zoomMeta: zoomMeta,
            onFocusRequest: { [weak self] in self?.focusDrawer(edge) })
        panel.translatesAutoresizingMaskIntoConstraints = false
        return panel
    }

    private func focusDrawer(_ edge: DrawerEdge) {
        let surface: TerminalSurface?
        switch edge {
        case .bottom:
            focusedPanel = .bottomDrawer
            bottomDrawerPanel?.isFocused = true
            rightDrawerPanel?.isFocused = false
            surface = bottomDrawerSurface
        case .right:
            focusedPanel = .rightDrawer
            rightDrawerPanel?.isFocused = true
            bottomDrawerPanel?.isFocused = false
            surface = rightDrawerSurface
        }
        paneCanvas.setPanesFocused(false)
        syncDrawerFocus()
        surface?.focus()
        onFocusChanged?()
    }

    func setFocusedSurfaceRendersFocused(_ focused: Bool) {
        switch focusedPanel {
        case .pane: paneCanvas.setFocusedSurfaceRendersFocused(focused)
        case .bottomDrawer: bottomDrawerSurface?.setFocused(focused)
        case .rightDrawer: rightDrawerSurface?.setFocused(focused)
        }
    }

    private func syncDrawerFocus() {
        bottomDrawerSurface?.setFocused(focusedPanel == .bottomDrawer)
        rightDrawerSurface?.setFocused(focusedPanel == .rightDrawer)
    }

    private func restoreFocusAfterClosingDrawer(otherOpen: Bool, other: DrawerEdge) {
        if otherOpen { focusDrawer(other) } else { paneCanvas.focusActivePane() }
    }

    private func paneGainedFocus() {
        focusedPanel = .pane
        paneCanvas.setPanesFocused(true)
        bottomDrawerPanel?.isFocused = false
        rightDrawerPanel?.isFocused = false
        syncDrawerFocus()
        onFocusChanged?()
    }

    func toggleZoom() {
        guard !isToolFloatOpen() else { return }
        if isZoomed { exitZoom(); return }
        switch focusedPanel {
        case .pane:
            guard !isSinglePane || isBottomOpen || isRightOpen else { toastFocusModeUnavailable(); return }
            zoomedPanel = .pane
            relayoutPanels()
            view.layoutSubtreeIfNeeded()
            paneCanvas.zoomFocusedLeaf(resizesCanvas: isBottomOpen || isRightOpen)
        case .bottomDrawer:
            guard isBottomOpen, let panel = bottomDrawerPanel else { return }
            panel.isZoomed = true
            zoomedPanel = .bottomDrawer
            relayoutPanels()
            popZoom(panel, growing: true)
        case .rightDrawer:
            guard isRightOpen, let panel = rightDrawerPanel else { return }
            panel.isZoomed = true
            zoomedPanel = .rightDrawer
            relayoutPanels()
            popZoom(panel, growing: true)
        }
    }

    private func exitZoom() {
        switch zoomedPanel {
        case .pane:
            zoomedPanel = nil
            relayoutPanels()
            view.layoutSubtreeIfNeeded()
            paneCanvas.unzoom(resizesCanvas: isBottomOpen || isRightOpen)
        case .bottomDrawer:
            bottomDrawerPanel?.isZoomed = false
            rightDrawerPanel?.isZoomed = false
            zoomedPanel = nil
            relayoutPanels()
            if let panel = bottomDrawerPanel { popZoom(panel, growing: false) }
        case .rightDrawer:
            bottomDrawerPanel?.isZoomed = false
            rightDrawerPanel?.isZoomed = false
            zoomedPanel = nil
            relayoutPanels()
            if let panel = rightDrawerPanel { popZoom(panel, growing: false) }
        case nil: return
        }
    }

    private func popZoom(_ view: NSView, growing: Bool) {
        view.superview?.layoutSubtreeIfNeeded()
        Motion.zoomPop(view, growing: growing)
    }

    private func switchZoomedDrawer(to edge: DrawerEdge) {
        switch edge {
        case .bottom:
            isBottomOpen = true
            _ = ensureBottomDrawerPanel()
            rightDrawerPanel?.isZoomed = false
            bottomDrawerPanel?.isZoomed = true
            zoomedPanel = .bottomDrawer
        case .right:
            isRightOpen = true
            _ = ensureRightDrawerPanel()
            bottomDrawerPanel?.isZoomed = false
            rightDrawerPanel?.isZoomed = true
            zoomedPanel = .rightDrawer
        }
        relayoutPanels()
        focusDrawer(edge)
    }

    @discardableResult func exitZoomIfNeeded() -> Bool {
        if isZoomed { exitZoom(); return true }
        return false
    }

    // Held chords auto-repeat, so repeats of one blocked verb coalesce into one toast.
    private var lastZoomBlockToast: (verb: String, at: Date)?
    private static let zoomBlockToastThrottle: TimeInterval = 3

    private var lastFocusUnavailableToast: Date?

    private var lastNoNeighborToast: (direction: Direction, at: Date)?

    private static var focusModeChord: String {
        Chord.displayed(.toggleZoom, in: GeneralConfig.current.keymap)?.displayGlyph ?? "Focus Mode"
    }

    private func toastZoomBlocked(_ verb: String) {
        let now = Date()
        if let last = lastZoomBlockToast, last.verb == verb,
            now.timeIntervalSince(last.at) < Self.zoomBlockToastThrottle
        {
            return
        }
        lastZoomBlockToast = (verb, now)
        onRequestToast?(
            ToastContent(
                variant: .info, title: "Focus Mode",
                message: "Exit Focus Mode (\(Self.focusModeChord)) to \(verb)."))
    }

    private func toastFocusModeUnavailable() {
        let now = Date()
        if let last = lastFocusUnavailableToast, now.timeIntervalSince(last) < Self.zoomBlockToastThrottle {
            return
        }
        lastFocusUnavailableToast = now
        onRequestToast?(
            ToastContent(
                variant: .info, title: "Focus Mode",
                message: "Focus Mode needs a second pane or an open drawer."))
    }

    private func toastNoNeighbor(_ direction: Direction) {
        let now = Date()
        if let last = lastNoNeighborToast, last.direction == direction,
            now.timeIntervalSince(last.at) < Self.zoomBlockToastThrottle
        {
            return
        }
        lastNoNeighborToast = (direction, now)
        let action: KeyInterceptor.ReservedChord
        let word: String
        switch direction {
        case .left: action = .navLeft; word = "left"
        case .right: action = .navRight; word = "right"
        case .up: action = .navUp; word = "up"
        case .down: action = .navDown; word = "down"
        }
        onRequestToast?(
            ToastContent(
                variant: .info,
                title: CommandCatalog.spec(for: action).title,
                message: "No pane \(word) to focus"))
    }

    // Pane leaf ids are non-negative, so drawer sentinels cannot collide with them.
    private static let bottomDrawerID = PaneID(Int.min)
    private static let rightDrawerID = PaneID(Int.min + 1)

    private var navReturn: [PaneID: [Direction: PaneID]] = [:]

    func navigate(_ direction: Direction) {
        if isZoomed { toastZoomBlocked("navigate"); return }
        var frames = paneCanvas.leafFrames(in: content)
        if isBottomOpen, let panel = bottomDrawerPanel {
            frames[Self.bottomDrawerID] = flippedFrame(of: panel)
        }
        if isRightOpen, let panel = rightDrawerPanel {
            frames[Self.rightDrawerID] = flippedFrame(of: panel)
        }

        let origin = currentPanelID
        let remembered = navReturn[origin]?[direction]
        let target =
            (remembered.map { isPanel($0, inDirection: direction, from: origin, frames: frames) } == true)
            ? remembered
            : nearestLeaf(from: origin, frames: frames, direction: direction)
        guard let target else {
            toastNoNeighbor(direction)
            return
        }

        navReturn[target, default: [:]][direction.opposite] = origin
        focusPanel(target)
    }

    func cyclePane(_ delta: Int) {
        if isZoomed { toastZoomBlocked("cycle"); return }
        var order = paneCanvas.orderedLeafIDs
        if isBottomOpen { order.append(Self.bottomDrawerID) }
        if isRightOpen { order.append(Self.rightDrawerID) }
        guard order.count > 1, let i = order.firstIndex(of: currentPanelID) else { return }
        focusPanel(order[(i + delta + order.count) % order.count])
    }

    private func pruneNavReturn(closed: [PaneID]) {
        navReturn = Self.navReturnPruned(navReturn, removing: Set(closed))
    }

    static func navReturnPruned(
        _ map: [PaneID: [Direction: PaneID]], removing closed: Set<PaneID>
    ) -> [PaneID: [Direction: PaneID]] {
        var result: [PaneID: [Direction: PaneID]] = [:]
        for (origin, inner) in map where !closed.contains(origin) {
            let kept = inner.filter { !closed.contains($0.value) }
            if !kept.isEmpty { result[origin] = kept }
        }
        return result
    }

    private var currentPanelID: PaneID {
        switch focusedPanel {
        case .pane: return paneCanvas.focusedLeafID
        case .bottomDrawer: return Self.bottomDrawerID
        case .rightDrawer: return Self.rightDrawerID
        }
    }

    private func focusPanel(_ id: PaneID) {
        if id == Self.bottomDrawerID {
            focusDrawer(.bottom)
        } else if id == Self.rightDrawerID {
            focusDrawer(.right)
        } else {
            paneCanvas.focusLeaf(id)
        }
    }

    // PaneKit's `lies`, not center offset, which let the right drawer pass as "up" from the bottom one.
    private func isPanel(
        _ candidate: PaneID, inDirection direction: Direction,
        from origin: PaneID, frames: [PaneID: CGRect]
    ) -> Bool {
        lies(candidate, inDirection: direction, from: origin, frames: frames)
    }

    func resize(_ direction: Direction) {
        if isZoomed { toastZoomBlocked("resize"); return }
        switch focusedPanel {
        case .pane:
            paneCanvas.resize(direction)
        case .bottomDrawer:
            let axis = content.bounds.height
            switch direction {
            case .up: bottomDrawerRatio = nudgedDrawerRatio(bottomDrawerRatio, by: Self.drawerResizeStep, along: axis)
            case .down:
                bottomDrawerRatio = nudgedDrawerRatio(bottomDrawerRatio, by: -Self.drawerResizeStep, along: axis)
            case .left, .right: NSSound.beep(); return
            }
            relayoutPanels()
        case .rightDrawer:
            let axis = content.bounds.width
            switch direction {
            case .left: rightDrawerRatio = nudgedDrawerRatio(rightDrawerRatio, by: Self.drawerResizeStep, along: axis)
            case .right: rightDrawerRatio = nudgedDrawerRatio(rightDrawerRatio, by: -Self.drawerResizeStep, along: axis)
            case .up, .down: NSSound.beep(); return
            }
            relayoutPanels()
        }
    }

    private func nudgedDrawerRatio(_ ratio: CGFloat, by deltaPixels: CGFloat, along axis: CGFloat) -> CGFloat {
        guard axis > 0 else { return ratio }
        let ceiling = max(Self.minDrawerExtent, axis * Self.maxDrawerFraction)
        let extent = min(max(ratio * axis + deltaPixels, Self.minDrawerExtent), ceiling)
        return extent / axis
    }

    private func flippedFrame(of panel: NSView) -> CGRect {
        let f = panel.convert(panel.bounds, to: content)
        let h = content.bounds.height
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    private func zoomedView(_ ref: PanelRef) -> NSView? {
        switch ref {
        case .pane: return canvas
        case .bottomDrawer: return bottomDrawerPanel
        case .rightDrawer: return rightDrawerPanel
        }
    }

    // Detached, not `isHidden`: a hidden view collapses to 0x0, resizing its PTY to 0 columns and crashing TUIs.
    private func setAttached(_ view: NSView, _ attached: Bool) {
        if attached {
            if view.superview !== content { content.addSubview(view) }
        } else if view.superview === content {
            view.removeFromSuperview()
        }
    }

    // Sign comes from constraint order, not the constant: a `-0.0` gutter is not `< 0`.
    func reapplyChromeLayout() {
        let gutter = ChromeMetrics.windowGutter
        for (index, constraint) in gutterConstraints.enumerated() {
            switch index {
            case 1: constraint.constant = -gutter
            case 2: constraint.constant = ChromeMetrics.topInset
            default: constraint.constant = gutter
            }
        }
        paneCanvas.reapplyChromeLayout()
        bottomDrawerPanel?.reapplyChromeLayout()
        rightDrawerPanel?.reapplyChromeLayout()
        relayoutPanels()
        view.layoutSubtreeIfNeeded()
    }

    func reapplyChromeColors() {
        paneCanvas.reapplyChromeColors()
        bottomDrawerPanel?.reapplyTheme()
        rightDrawerPanel?.reapplyTheme()
    }

    private func beginDrawerSlide() {
        activeDrawerSlides += 1
        if activeDrawerSlides == 1 { allSurfaces.forEach { $0.setSizeSyncSuspended(true) } }
        SlideClip.apply(to: content)
    }

    private func endDrawerSlide() {
        activeDrawerSlides = max(0, activeDrawerSlides - 1)
        if activeDrawerSlides == 0 {
            SlideClip.remove(from: content)
            allSurfaces.forEach { $0.setSizeSyncSuspended(false) }
        }
    }

    private func runDrawerSlide(
        panel: PanelHostView, opening: Bool, parkOffset: CGVector,
        animate: [(constraint: NSLayoutConstraint, to: CGFloat)], isCurrent: @escaping () -> Bool
    ) {
        let slideStarts = animate.map(\.constraint.constant)
        for (constraint, target) in animate { constraint.constant = target }
        content.layoutSubtreeIfNeeded()
        beginDrawerSlide()
        for (pair, start) in zip(animate, slideStarts) { pair.constraint.constant = start }
        content.layoutSubtreeIfNeeded()

        let parked = CATransform3DMakeTranslation(parkOffset.dx, parkOffset.dy, 0)
        let restT = opening ? CATransform3DIdentity : parked
        panel.wantsLayer = true
        panel.layer?.transform = restT
        let slideAnim = CABasicAnimation(keyPath: "transform")
        slideAnim.fromValue = NSValue(caTransform3D: opening ? parked : CATransform3DIdentity)
        slideAnim.toValue = NSValue(caTransform3D: restT)
        slideAnim.duration = Motion.pageSlideDuration
        slideAnim.timingFunction = Motion.landingTiming

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.pageSlideDuration
            ctx.timingFunction = Motion.landingTiming
            for (constraint, target) in animate { constraint.animator().constant = target }
            panel.layer?.add(slideAnim, forKey: "drawer.slide")
        } completionHandler: { [weak self] in
            guard let self else { return }
            let isLastSlide = self.activeDrawerSlides <= 1
            if isCurrent() {
                if !opening { self.setAttached(panel, false) }
                panel.layer?.transform = CATransform3DIdentity
                if isLastSlide { self.relayoutPanels() }
            }
            self.endDrawerSlide()
        }
    }

    private func animateBottomDrawer(opening: Bool) {
        guard let bottomPanel = bottomDrawerPanel else {
            relayoutPanels()
            return
        }
        content.layoutSubtreeIfNeeded()
        let target = max(0, content.bounds.height * bottomDrawerRatio)
        let slide = target + ChromeMetrics.panelGap

        NSLayoutConstraint.deactivate(tileConstraints)
        setAttached(bottomPanel, true)
        let canvasBottomC = canvas.bottomAnchor.constraint(
            equalTo: content.bottomAnchor, constant: opening ? 0 : -slide)
        let drawerHeight = bottomPanel.heightAnchor.constraint(equalToConstant: target)
        drawerHeight.priority = .defaultHigh
        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvasBottomC,
            bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            drawerHeight,
        ]
        if isRightOpen, let rightPanel = rightDrawerPanel {
            let width = rightPanel.widthAnchor.constraint(
                equalTo: content.widthAnchor, multiplier: rightDrawerRatio)
            width.priority = .defaultHigh
            cs += [
                rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
                rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                width,
                canvas.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap),
                bottomPanel.trailingAnchor.constraint(
                    equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap),
            ]
        } else {
            cs += [
                canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                bottomPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(cs)
        tileConstraints = cs
        content.layoutSubtreeIfNeeded()

        bottomDrawerAnimationID &+= 1
        let id = bottomDrawerAnimationID
        runDrawerSlide(
            panel: bottomPanel, opening: opening, parkOffset: CGVector(dx: 0, dy: -slide),
            animate: [(canvasBottomC, opening ? -slide : 0)],
            isCurrent: { [weak self] in self?.bottomDrawerAnimationID == id })
    }

    private func animateRightDrawer(opening: Bool) {
        guard let rightPanel = rightDrawerPanel else {
            relayoutPanels()
            return
        }
        content.layoutSubtreeIfNeeded()
        let target = max(0, content.bounds.width * rightDrawerRatio)
        let slide = target + ChromeMetrics.panelGap

        NSLayoutConstraint.deactivate(tileConstraints)
        setAttached(rightPanel, true)
        let canvasTrailingC = canvas.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: opening ? 0 : -slide)
        let drawerWidth = rightPanel.widthAnchor.constraint(equalToConstant: target)
        drawerWidth.priority = .defaultHigh
        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvasTrailingC,
            rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            drawerWidth,
        ]
        var bottomTrailingC: NSLayoutConstraint?
        if isBottomOpen, let bottomPanel = bottomDrawerPanel {
            let height = bottomPanel.heightAnchor.constraint(
                equalTo: content.heightAnchor, multiplier: bottomDrawerRatio)
            height.priority = .defaultHigh
            let trailing = bottomPanel.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: opening ? 0 : -slide)
            bottomTrailingC = trailing
            cs += [
                bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                height,
                trailing,
                canvas.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -ChromeMetrics.panelGap),
            ]
        } else {
            cs.append(canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor))
        }
        NSLayoutConstraint.activate(cs)
        tileConstraints = cs
        content.layoutSubtreeIfNeeded()

        rightDrawerAnimationID &+= 1
        let id = rightDrawerAnimationID
        var animate: [(constraint: NSLayoutConstraint, to: CGFloat)] = [(canvasTrailingC, opening ? -slide : 0)]
        if let bottomTrailingC { animate.append((bottomTrailingC, opening ? -slide : 0)) }
        runDrawerSlide(
            panel: rightPanel, opening: opening, parkOffset: CGVector(dx: slide, dy: 0),
            animate: animate, isCurrent: { [weak self] in self?.rightDrawerAnimationID == id })
    }

    private func relayoutPanels() {
        NSLayoutConstraint.deactivate(tileConstraints)
        tileConstraints = []

        let effectiveZoom: PanelRef? = zoomedPanel.flatMap { zoomedView($0) != nil ? $0 : nil }

        let canvasVisible: Bool
        let bottomVisible: Bool
        let rightVisible: Bool
        if let z = effectiveZoom {
            canvasVisible = z == .pane
            bottomVisible = z == .bottomDrawer
            rightVisible = z == .rightDrawer
        } else {
            canvasVisible = true
            bottomVisible = isBottomOpen
            rightVisible = isRightOpen
        }
        setAttached(canvas, canvasVisible)
        if let p = bottomDrawerPanel { setAttached(p, bottomVisible) }
        if let p = rightDrawerPanel { setAttached(p, rightVisible) }

        if let z = effectiveZoom, let zv = zoomedView(z) {
            let cs = [
                zv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                zv.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                zv.topAnchor.constraint(equalTo: content.topAnchor),
                zv.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ]
            NSLayoutConstraint.activate(cs)
            tileConstraints = cs
            return
        }

        var cs: [NSLayoutConstraint] = [
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
        ]

        if isRightOpen, let rightPanel = rightDrawerPanel {
            let width = rightPanel.widthAnchor.constraint(
                equalTo: content.widthAnchor, multiplier: rightDrawerRatio)
            width.priority = .defaultHigh
            cs += [
                rightPanel.topAnchor.constraint(equalTo: content.topAnchor),
                rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                width,
                canvas.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap),
            ]
        } else {
            cs.append(canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor))
        }

        if isBottomOpen, let bottomPanel = bottomDrawerPanel {
            let height = bottomPanel.heightAnchor.constraint(
                equalTo: content.heightAnchor, multiplier: bottomDrawerRatio)
            height.priority = .defaultHigh
            cs += [
                bottomPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                height,
                canvas.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -ChromeMetrics.panelGap),
            ]
            if isRightOpen, let rightPanel = rightDrawerPanel {
                cs.append(
                    bottomPanel.trailingAnchor.constraint(
                        equalTo: rightPanel.leadingAnchor, constant: -ChromeMetrics.panelGap))
            } else {
                cs.append(bottomPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor))
            }
        } else {
            cs.append(canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor))
        }

        NSLayoutConstraint.activate(cs)
        tileConstraints = cs
    }
}

extension TabController: TerminalSurfaceDelegate {
    // Pane events already arrive through `PaneCanvasController`; forwarding them too would double them.
    private func relay(_ s: TerminalSurface, _ event: SurfaceEvent) {
        guard s === bottomDrawerSurface || s === rightDrawerSurface else { return }
        onSurfaceEvent?(s, event)
    }
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition) {
        relay(s, .scrollPosition(position))
    }
    func surfaceGridDidReflow(_ s: TerminalSurface) {
        relay(s, .gridReflow)
    }
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?) {
        relay(s, .search(.total(total)))
    }
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?) {
        relay(s, .search(.selected(index)))
    }
    func surfaceDidEndSearch(_ s: TerminalSurface) {
        relay(s, .search(.ended))
    }
    func surface(_ s: TerminalSurface, wantsSearchWithNeedle needle: String) {
        relay(s, .search(.wanted(needle: needle)))
    }
    func surfaceWantsFocus(_ s: TerminalSurface) {
        if s === bottomDrawerSurface { focusDrawer(.bottom) } else if s === rightDrawerSurface { focusDrawer(.right) }
    }
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        guard let id = drawerSurfaceID(of: s) else { return }
        onNotification?(id, n)
    }
    func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {
        guard let id = drawerSurfaceID(of: s) else { return }
        onCommandFinished?(id, result)
    }
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {
        guard let id = drawerSurfaceID(of: s) else { return }
        onProgress?(id, p)
    }

    private func drawerSurfaceID(of s: TerminalSurface) -> SurfaceID? {
        if s === bottomDrawerSurface { return bottomDrawerSurfaceID }
        if s === rightDrawerSurface { return rightDrawerSurfaceID }
        return nil
    }
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {
        if s === bottomDrawerSurface {
            bottomDrawerPanel?.backgroundOverride = color
        } else if s === rightDrawerSurface {
            rightDrawerPanel?.backgroundOverride = color
        }
    }
    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?) {
        if s === bottomDrawerSurface, let panel = bottomDrawerPanel {
            LinkPreviewPresenter.shared.update(url, near: panel)
        } else if s === rightDrawerSurface, let panel = rightDrawerPanel {
            LinkPreviewPresenter.shared.update(url, near: panel)
        }
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        if s === bottomDrawerSurface {
            closeDrawer(.bottom)
        } else if s === rightDrawerSurface {
            closeDrawer(.right)
        }
    }

    private func closeDrawer(_ edge: DrawerEdge) {
        let ref: PanelRef
        switch edge {
        case .bottom:
            ref = .bottomDrawer
            if zoomedPanel == .bottomDrawer { zoomedPanel = nil }
            bottomDrawerPanel?.removeFromSuperview()
            bottomDrawerSurface?.terminate()
            bottomDrawerSurface = nil
            bottomDrawerPanel = nil
            unregisterDrawerToken(.bottomDrawer)
            isBottomOpen = false
        case .right:
            ref = .rightDrawer
            if zoomedPanel == .rightDrawer { zoomedPanel = nil }
            rightDrawerPanel?.removeFromSuperview()
            rightDrawerSurface?.terminate()
            rightDrawerSurface = nil
            rightDrawerPanel = nil
            unregisterDrawerToken(.rightDrawer)
            isRightOpen = false
        }
        relayoutPanels()
        if focusedPanel == ref {
            if isToolFloatOpen() { focusedPanel = .pane } else { paneCanvas.focusActivePane() }
        }
    }

    func surfaceDidFailToStart(_ s: TerminalSurface) {
        let descriptor: String
        if s === bottomDrawerSurface {
            descriptor = "The bottom drawer"
        } else if s === rightDrawerSurface {
            descriptor = "The right drawer"
        } else {
            return
        }
        warnSurfaceFailed(descriptor: descriptor)
        surfaceDidExit(s, code: nil)
    }

    private func warnSurfaceFailed(descriptor: String) {
        onRequestToast?(
            ToastContent(
                variant: .warning, title: "Terminal Didn't Start",
                message: "\(descriptor) failed to launch. Open it again to retry."))
    }
}
