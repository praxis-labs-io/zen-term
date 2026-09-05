import AppKit
import AppLog
import TabKit
import TerminalKit
import UniformTypeIdentifiers

/// Owns one window and its independent set of tabs. Each tab is a
/// `TabController` (wrapping Epic 1's pane tree + registry + focus). Only the active
/// tab's `view` is mounted; inactive tabs are detached but retained, so their
/// shells keep running. The tab bar is pinned to the bottom.
@MainActor
final class WindowController: NSObject {
    let window: HostWindow

    private var tabs: TabList
    private var controllers: [TabID: TabController] = [:]
    private var titles: [TabID: String] = [:]
    /// Background tabs with an attention event own one persistent toast and one explicit state.
    /// Waiting for agent input outranks command completion, so a completion can never replace a
    /// request that still needs the user. Both clear when the tab is shown or closed.
    private var attentionToasts: [TabID: ToastView] = [:]
    private var attentionStates: [TabID: TabAttentionState] = [:]
    private static let commandCompletionThreshold: TimeInterval = 10
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
    /// Top-right transient notices, built on first use so the stack mounts above the canvas, and
    /// window-level so every tab shares it. An explicit optional rather than `lazy` because
    /// touching a `lazy var` to re-inset it would construct one in every window instead.
    private var builtToasts: ToastPresenter?
    private var toasts: ToastPresenter {
        if let builtToasts { return builtToasts }
        // Below an open card, not on top of it: the stack is built on the first toast of the window's
        // life, which can be a toast fired while a card is already up. A card opened later
        // lands above the stack on its own, being added at the front.
        let presenter = ToastPresenter(
            host: container, below: modal?.overlay, topInset: Self.toastTopInset,
            trailingInset: Self.toastTrailingInset, dismissAfter: GeneralConfig.current.toastDuration)
        builtToasts = presenter
        return presenter
    }

    /// The toast stack's offsets from the tile region, single-sourced so construction and the
    /// live re-apply can't drift apart.
    private static var toastTopInset: CGFloat { ChromeMetrics.topInset + 12 }
    private static var toastTrailingInset: CGFloat { ChromeMetrics.windowGutter + 12 }

    /// Surface a notice in this window. The seam for app-global notices (`AppDelegate` routes
    /// config problems to one window this way) — the presenter itself stays private so nothing
    /// outside can reach into this window's toast stack.
    func showToast(_ content: ToastContent) { toasts.show(content) }

    /// The font-size card currently up in this window, if any, held so a repeat re-labels it rather
    /// than stacking a second one (see `FontSizeCard`).
    private var fontSizeCard: FontSizeCard?
    /// The pending dismissal, cancelled and re-armed on every step so the card lives a full beat
    /// past the *last* keystroke rather than the first.
    private var fontSizeDismissal: DispatchWorkItem?
    /// How long the card stays up after the last step. Shorter than a toast's 4s: it reports a state
    /// the user is actively driving and can re-raise with one keystroke, so it shouldn't sit over
    /// the terminal once they've stopped.
    private static let fontSizeCardLinger: TimeInterval = 1.2

    /// Show (or re-label) the font-size card. Called on the key window only — `AppDelegate` owns the
    /// size itself and pushes it to every window; this is just where the number is read.
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

    /// Push the session font size to every terminal surface this window owns: the panes of every
    /// tab, both drawers, and any tool float, open or standing by.
    ///
    /// A separate pass rather than a value folded into `applyAppearance`, because once a surface
    /// has an explicit size libghostty stops applying config reloads to its font.
    func applySessionFontSize() {
        for surface in allTerminalSurfaces { surface.setFontSize(SessionFontSize.points) }
        // A font step changes the cell height without moving any view's frame, so nothing lays
        // out and the cursor band would keep drawing at the old row height over text that just
        // re-flowed at the new one.
        scrollMode.refreshGeometry()
    }

    /// Every terminal surface under this window: the pane trees of all tabs plus the tool floats.
    /// Single-sourced because the appearance re-apply and the font-size push must not drift — a
    /// surface either collection missed would keep a stale font or a stale theme.
    private var allTerminalSurfaces: [TerminalSurface] {
        controllers.values.flatMap { $0.allSurfaces } + floats.allSurfaces
    }

    /// Host the app-global update card in this window's toast stack. `UpdateController`
    /// presents into the key window this way and re-homes here if its prior host closes.
    func presentUpdateCard(_ card: UpdateCardView) { toasts.present(card: card) }

    /// Remove the update card this window is hosting. Arm dismissal first so a click landing on the
    /// card while it springs out can't fire a stale Sparkle reply.
    func dismissUpdateCard(_ card: UpdateCardView) {
        card.beginDismissal()
        toasts.remove(card: card)
    }

    /// Save-panel wiring over `DiagnosticsBundleBuilder`: pick a destination, then build the
    /// zip off the main thread and confirm or report with a toast. The log set is the live
    /// sink's files; with no sink the bundle is just system metadata, still worth exporting.
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

    /// The window's tool floats. One engine per window, and the card always hosts on `container` so
    /// a tab switch doesn't unmount it. How many live instances a float has is its `scope`: a
    /// `.window` float is shared by every tab, a `.tab` one (Scratch alone) gets one per tab and
    /// dies with it. Lazy so `container`, `tabBar`, and the tab machinery all exist before the
    /// closures below can run.
    private lazy var floats: ToolFloatController = {
        let controller = ToolFloatController(
            presentOverlay: { [weak self] overlay in self?.presentWindowFloat(overlay) },
            focusedCWD: { [weak self] in self?.activeController?.focusedCWD },
            yieldFocus: { [weak self] in
                // A float takes the keyboard without moving pane focus, so the focus relay never
                // fires and a mode would stay up swallowing the keys meant for the float.
                self?.endModes()
                self?.activeController?.yieldFocusToFloat()
            },
            // No `endModes()` to mirror `yieldFocus`: restoring unified focus announces the move,
            // and that relay already ends both modes. Opening is the asymmetric one.
            restoreFocus: { [weak self] in self?.activeController?.restoreUnifiedFocus() },
            // Guarded like `activeController`: `TabList.activeID` preconditions on a non-empty list,
            // and `closeTab` empties it before the teardown that re-renders the dock through here.
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

    /// The shown float card's gutter insets, retained so a live `window-gutter` change re-insets
    /// it (`reapplyFloatLayout`). Nil until the first float opens.
    private var floatGutter:
        (
            leading: NSLayoutConstraint, trailing: NSLayoutConstraint, top: NSLayoutConstraint,
            bottom: NSLayoutConstraint
        )?

    /// What kind of card the chord gate closed to open something else, so the surface opening in its
    /// place can hand back to it. Lives for one `handle(_:)` call, which clears it on entry.
    private var closingModalKind: ModalKind?

    /// Where the tool-float form on screen hands back to. Kept beside the card rather than only in its
    /// closure, because the form is itself in the gate's close list: pressing the New Tool Float chord
    /// over an open form replaces it, and the replacement has to inherit the first one's way back
    /// instead of dropping the user out of the Settings session it was opened from.
    private var toolFormReturn: ToolFormReturn?

    /// The open modal card's gutter insets, retained for the same reason `floatGutter` is. Nil while
    /// no card is up.
    private var modalGutter:
        (
            leading: NSLayoutConstraint, trailing: NSLayoutConstraint, top: NSLayoutConstraint,
            bottom: NSLayoutConstraint
        )?

    private let tabBar: TabBarView
    private let dock: ToggleDock
    private var mountedCanvas: NSView?

    /// Which modal card is open. The workspace picker (⌘P), command palette (⌘⇧P), and Add-Workspace
    /// form are mutually exclusive — only one is up at a time — so they share a single slot with
    /// a kind discriminator rather than parallel per-overlay stacks. Window-level (they open/
    /// switch tabs) but presented over the active tab's tile region. Modal while open.
    private enum ModalKind {
        case repoPicker, commandPalette, workspaceForm, settings, toolFloatForm, reportIssue
        case renameTab

        /// The chord that closes this same modal when pressed again (its own toggle), or nil for a
        /// card with no dedicated chord (the workspace / tool-float / report forms, reached from a
        /// picker, a Settings section, or the Help menu) — those are still closed by any
        /// surface-switch chord in `handle(_:)`, just not self-toggled.
        var selfToggle: KeyInterceptor.ReservedChord? {
            switch self {
            case .repoPicker: return .toggleRepoPicker
            case .commandPalette: return .toggleCommandPalette
            case .settings: return .openSettings
            case .workspaceForm, .toolFloatForm, .reportIssue, .renameTab: return nil
            }
        }
    }
    private var modal: (overlay: ModalOverlay, kind: ModalKind)?

    /// A card that has been asked for but can't be built yet, because its content is still being
    /// read off the main thread (the `workspaces` file). Nothing is on screen for it, so
    /// this is its only trace: a second press must not start a second load and present twice, and a
    /// load landing after an Esc or after another card went up must not present at all.
    private var pendingModal: ModalKind?

    /// The app's key interceptor, injected so the Settings Keybinds section can capture chords.
    weak var keybindCapturer: KeybindCapturing?

    /// The same interceptor, injected under the narrower capability scroll mode needs. The
    /// handler is installed only while the mode is up, so an idle app pays one nil check per
    /// keystroke rather than a chain of lookups into every window.
    weak var keyModeHost: KeyModeHosting?

    /// Scroll mode over this window's focused panel. Per window because it targets one
    /// panel, and the key handler it installs is app-global, so only the key window's can be up.
    let scrollMode = ScrollModeController()

    /// Find over the same panel. Per window for the same reasons, and it
    /// drives scroll mode on commit, so it holds the one above.
    lazy var search = SearchController(scrollMode: scrollMode)

    /// Hand an app-global chord back to `AppDelegate.route`. The keyboard path routes these before
    /// `handle(_:)`, but a palette pick reaches `handle` directly — where they'd otherwise be a
    /// no-op — so `handle` forwards them here instead. Injected by `AppDelegate`.
    var onAppGlobalCommand: ((KeyInterceptor.ReservedChord) -> Void)?

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

    /// Whether a tool float card is up. Read by the key pass-through guard: a float is modal, so
    /// the window swallows nav rather than acting on it, and a consumed `Ctrl`-nav chord would be
    /// taken from the tool for nothing.
    var isToolFloatOpen: Bool { floats.isOpen }

    /// The shown float's tool name for copy: its title with a leading "Open " stripped, so a
    /// notice reads "Lazygit", not "Open Lazygit". Nil when nothing is shown, letting each call
    /// site pick the fallback its sentence needs ("the tool" mid-sentence, "This tool" to open one).
    private var activeFloatName: String? {
        floats.activeID.flatMap(ToolFloatCatalog.byID)
            .map { $0.title.replacingOccurrences(of: "Open ", with: "") }
    }

    /// How long the "a float is up" notice stays coalesced. Held chords auto-repeat, so without
    /// this a leaned-on ⌘F stacks one card per keystroke. Matches the zoom-block throttle.
    private static let floatBlockToastThrottle: TimeInterval = 3
    private var lastFloatBlockToast: Date?

    /// A pane command was pressed while a tool float is up. The float is modal, so the window
    /// swallows every one of them; say why instead of doing nothing. Deliberately not keyed by
    /// chord: the notice reads the same whichever was pressed.
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
            // The float tail is the user's floats alone: the built-in Scratch float has its own
            // fixed button, and passing the whole catalog here would draw a second one.
            toolFloats: ToolFloatCatalog.userDefined, onToolFloat: { onToolFloat($0) },
            hiddenButtons: GeneralConfig.current.hiddenToolbarButtons)
        super.init()
        nextTabID = 2

        onSelect = { [weak self] in self?.select($0) }
        onClose = { [weak self] in self?.closeTab($0) }
        onRename = { [weak self] in self?.openRenameTab($0) }
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
        wireModes()

        // Layout & Motion knobs (backdrop tint, window gutter, pane gap) re-apply live: a
        // Settings-card edit re-tints the backdrop and re-lays-out every built tab, no relaunch.
        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            // `queue: .main` guarantees this block lands on the main thread; assert that
            // rather than hop, so the re-apply happens in the same turn as the post.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Each block below runs only when the config it actually reads moved. The
                // dependencies are what the call chain *resolves*, not what it's named after: recoloring
                // a pane rebuilds its header keycap from the live keymap, so a rebind lands there too.
                let change = ConfigChange.from(note)

                if change.contains(.theme) || change.contains(.chromeLayout) {
                    self.tint.layer?.backgroundColor =
                        Theme.current.chrome.background.nsColor.withAlphaComponent(Self.backdropTintAlpha)
                        .cgColor
                }
                if change.contains(.chromeLayout) {
                    // Show/hide the traffic lights live; `reapplyChromeLayout()` below re-applies the
                    // matching top inset so the header space appears/reclaims without a relaunch.
                    self.window.setWindowChromeVisible(GeneralConfig.current.windowChrome)
                    for controller in self.controllers.values { controller.reapplyChromeLayout() }
                    self.reapplyFloatLayout()  // a gutter change must re-inset an OPEN card too
                    self.reapplyModalLayout()
                    // Only if a toast has already been shown — see `builtToasts`.
                    self.builtToasts?.reapplyInsets(
                        topInset: Self.toastTopInset, trailingInset: Self.toastTrailingInset)
                }
                // `reapplyChromeColors` rebuilds the panel header's keycap against the live keymap,
                // so a rebind needs it too, not just a theme swap. `.terminalBehavior` because that
                // call also re-reads `background-alpha` to decide what fills the panel.
                if change.contains(.theme) || change.contains(.keymap)
                    || change.contains(.terminalBehavior)
                {
                    for controller in self.controllers.values { controller.reapplyChromeColors() }
                }
                // An open tool float re-reads `background-alpha` to decide whether its card fills its
                // own interior or its ring does, exactly as `PanelHostView` does above — so
                // `.terminalBehavior` has to reach it, or editing the value leaves the card up at its
                // old fill until it is closed and reopened.
                if change.contains(.theme) || change.contains(.terminalBehavior) {
                    self.floats.reapplyTheme()
                }
                if change.contains(.theme) {
                    self.tabBar.reapplyTheme()
                    self.dock.reapplyTheme()
                    self.confirmToast?.reapplyTheme()
                    // Attention toasts are sticky with no auto-dismiss, so one left up across a theme edit
                    // would otherwise keep its old card fill, ink, and ⌘N keycap — washed out over the new
                    // chrome until the user dismisses it.
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
                    // Unconditionally, because both halves fail silently otherwise: a stepped
                    // surface ignores the theme size that just landed, while a surface spawned at
                    // the stepped size follows the theme back down, leaving one tab's panes at
                    // different sizes after any theme edit.
                    self.applySessionFontSize()
                }
                if change.contains(.floats) {
                    // A float add / edit / remove changes the catalog — rebuild the dock's per-float
                    // buttons (not just recolor) so the toolbar reflects it live, then restore active
                    // states. Prune the float registry against the same catalog: a deleted float's
                    // hidden process would otherwise keep running with no control able to ever reach it.
                    self.floats.prune(against: ToolFloatCatalog.all)
                    self.dock.setToolFloats(ToolFloatCatalog.userDefined)
                    self.dock.reapplyTheme()  // the rebuilt buttons bake their colors in at build time
                    self.renderDock()
                }
                if change.contains(.toolbarButtons) {
                    self.dock.setHiddenButtons(GeneralConfig.current.hiddenToolbarButtons)
                }
                // An open palette re-resolves its whole catalog here, so this tracks more than a
                // recolor: `.keymap` because a row's shortcut column resolves from the live keymap,
                // `.floats` because every tool float is also a palette command.
                //
                // `.floats` only bites across two windows, which is worth knowing before anyone
                // simplifies it away: a palette open in window A while window B saves a float.
                if change.contains(.theme) || change.contains(.keymap) || change.contains(.floats) {
                    self.modal?.overlay.reapplyTheme()
                }
            }
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
        // hosted here is layer-backed, and one dropped into a non-layer-backed parent
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

    /// Enter scroll mode over the focused panel, or leave it if it is already up.
    ///
    /// A panel with no live surface (a drawer that has never been opened) has nothing to scroll,
    /// so the chord does nothing rather than putting up a mode over an empty panel.
    private func toggleScrollMode() {
        // A reserved chord routes ahead of the mode handler, so this fires while the find field
        // holds the keyboard. Starting the mode there would put its header and cursor up over a
        // mode that cannot receive a single key, because the phase-one gate stands the handler
        // down. Committing hands the keys back and brings scroll mode up as a matter of course.
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

    /// Open the find bar over the focused panel, or put the caret back in it if it is already up.
    ///
    /// A panel with no live surface has nothing to search, so the chord does nothing rather than
    /// putting a bar over an empty panel.
    private func toggleSearch() {
        guard let target = modeTarget else { return }
        // Seeded from whichever selection model is live: scroll mode's `v` is the chrome's own
        // overlay, which the backend cannot see, and a mouse drag is libghostty's. `copySelection`
        // is a pure read despite the name, and touches no pasteboard.
        let selected = scrollMode.selectedText ?? target.surface.copySelection()
        search.begin(surface: target.surface, panel: target.host, seed: selected ?? "")
    }

    /// Open the find bar on the selection, and do nothing when there is none. That last clause is
    /// the whole difference from `toggle_search`, which reads the same two selection models but
    /// opens on an empty needle rather than declining.
    private func searchSelection() {
        guard let target = modeTarget else { return }
        guard let selected = scrollMode.selectedText ?? target.surface.copySelection(),
            !selected.isEmpty
        else { return }
        search.begin(surface: target.surface, panel: target.host, seed: selected)
    }

    /// The surface a reading chord acts on, and the card to hang its strips off. A shown float owns
    /// both while it is up, because it is modal over the panes behind it.
    private var modeTarget: (surface: TerminalSurface, host: TerminalModeHost)? {
        if let shown = floats.shownTarget { return shown }
        guard let panel = activeController?.focusedScrollTarget else { return nil }
        return (panel.surface, panel.panel)
    }

    /// Move the focused pane or drawer's viewport, leaving the keyboard where it is. Scroll mode is
    /// the other way to read back through a buffer; this is one press and no mode.
    private func scrollFocusedPane(_ command: TerminalScroll) {
        modeTarget?.surface.scroll(command)
    }

    /// Paste what is selected back into the pane it came from, and do nothing when nothing is.
    /// Reads both selection models, the same pair ⌘E does.
    ///
    /// Not the pasteboard, which is ⌘V's job: ghostty's `paste_from_selection` means the X11
    /// selection clipboard, which macOS does not have, so on this platform that chord would paste
    /// exactly what ⌘V does.
    private func pasteSelection() {
        guard let target = modeTarget else { return }
        guard let selected = scrollMode.selectedText ?? target.surface.copySelection(),
            !selected.isEmpty
        else { return }
        target.surface.paste(selected)
    }

    /// Feed one surface report to whichever mode wants it. A pane, a drawer and a tool float all
    /// reach this, so the three relays cannot drift apart.
    private func report(_ surface: TerminalSurface, _ event: SurfaceEvent) {
        switch event {
        case .scrollPosition(let position):
            scrollMode.report(position: position, from: surface)
            // Search reads the same report for a different reason: to know where the viewport
            // sat when the bar went up, so it can put it back there rather than at the live end.
            search.report(position: position, from: surface)
        case .gridReflow:
            scrollMode.reportReflow(from: surface)
        case .search(let event):
            // The host is resolved lazily: only the backend's own open-a-bar request needs one,
            // and every other event is for a bar that is already up.
            search.handle(event, from: surface, panel: modeTarget?.host)
        }
    }

    /// End both modes, in the order their layout changes have to unwind: the bar comes down first,
    /// because taking it down reflows the grid scroll mode is still measuring against.
    private func endModes() {
        search.end()
        scrollMode.end()
    }

    /// Install the key handler for exactly as long as a mode is up, and route scroll reports into
    /// it. Both halves live here because the controllers own their modes, not the window's
    /// plumbing.
    private func wireModes() {
        // `*` opens the find bar on the word the band is on, the same entry ⌘F uses on a selection.
        scrollMode.onSearchWord = { [weak self] word in
            guard let target = self?.modeTarget else { return }
            self?.search.begin(surface: target.surface, panel: target.host, seed: word)
        }
        scrollMode.onActiveChanged = { [weak self] active in
            guard let self else { return }
            // The bar up means the keyboard belongs to the search: to the field while the needle is
            // typed, to scroll mode once ⏎ hands it over. Leaving the mode makes the prompt live,
            // so the bar goes with it however the reader left: `q`, `i` or the chord.
            //
            // Who started the mode does not come into it, which is where this parts company with
            // Esc: Esc leaves a reader-owned mode alone precisely because the prompt stays dead.
            //
            // Re-entrant, and has to stay safe. `search.end()` tears down through
            // `scrollMode.end()`, which lands back here; both controllers guard on their own
            // `isActive`, so the second pass returns without doing anything.
            if !active { self.search.end() }
            self.updateModeHandler()
        }
        search.onActiveChanged = { [weak self] _ in self?.updateModeHandler() }
    }

    /// One handler for both modes, because `KeyInterceptor` has one slot. While the find field
    /// holds first responder the handler stands down entirely: the interceptor runs ahead of the
    /// field editor, so a mode that kept claiming keys would leave the bar untypeable.
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
        // A mode holds the keyboard, so the shell's cursor stands down (hollow, still) for as
        // long as it is up. Released against the tab it was pushed at, never whichever is active.
        if let previous = modeRenderTarget, previous !== activeController {
            previous.setFocusedSurfaceRendersFocused(true)
        }
        modeRenderTarget = active ? activeController : nil
        activeController?.setFocusedSurfaceRendersFocused(!active)
    }

    /// The tab whose focused surface currently wears a mode's unfocused render.
    private weak var modeRenderTarget: TabController?

    /// Build the first tab, start its shell, and arm the title poll. Does **not** present the
    /// window: ordering it in and taking key belongs to whoever asked for the window, because a
    /// test wants everything here and none of that. A run of the window suites ordered 40+ real
    /// windows across Spaces and took key from whatever the developer was typing in, once per test.
    func mountAndStart() {
        bindFirstControllerIfNeeded()
        mount(.instant)
        activeController?.start()
        renderTabBar()
        // Ordering a window in is what used to run the first layout pass, and the pane tree needs
        // real sizes before anything acts on it: `PaneCanvasController.split` refuses on a host
        // narrower than `minSplitExtent`, and a zero-size host is every host until layout runs.
        window.contentView?.layoutSubtreeIfNeeded()
        titlePoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            // Scheduled on the main runloop, so it fires on the main thread — assert, don't hop.
            MainActor.assumeIsolated { self?.refreshTitlesFromCWD() }
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

        // Busy state has no push event, so poll it here (building the overlay once) and re-render
        // the dock only when one of the three actually flips.
        if busyDots() != lastBusyDots { renderDock() }
    }

    /// The active tab's (bottom drawer, right drawer, Scratch) busy state, which drives their
    /// activity dots and surfaces any of the three that `hide-toolbar-buttons` hides.
    private func busyDots() -> (Bool, Bool, Bool) {
        let overlay = activeController?.overlayState
        return (
            overlay?.bottomBusy ?? false, overlay?.rightBusy ?? false,
            floats.isBusy(ToolFloat.scratch.id)
        )
    }

    /// `busyDots()` as of the last `renderDock()` — so the poll re-renders only when a dot actually
    /// flips. Updated on every dock render (including tab switches), so a switch to a
    /// differently-busy tab can't leave it stale.
    private var lastBusyDots = (false, false, false)

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

    /// The incoming tab's canvas slides in from this edge.
    enum SlideEdge { case fromRight, fromLeft }

    /// How the active tab's canvas replaces the previous one.
    enum MountTransition {
        case instant  // the window's first mount, tab close, replace-in-place
        case slide(from: SlideEdge)  // switching between tabs, and a new tab entering from the right
    }

    /// Mount the active tab's canvas above the tab bar, replacing the previous one with the given
    /// transition, and restore focus to the active tab. Animated transitions defer the previous
    /// canvas's removal to their completion, guarded so a rapid re-switch cannot delete the
    /// now-active terminal.
    ///
    /// `onLanded` runs when an animated transition's motion finishes. A transition that has
    /// already landed by the time this returns never calls it and says so by **returning true**,
    /// so a caller sequencing work after the mount handles that case itself.
    @discardableResult
    private func mount(_ transition: MountTransition, onLanded: (() -> Void)? = nil) -> Bool {
        guard let c = activeController, mountedCanvas !== c.view else {
            restoreFocusToActive()  // same canvas: just refresh focus/dock
            renderDock()
            return true  // nothing mounted, so nothing to wait for
        }
        let outgoing = mountedCanvas
        pinCanvas(c.view)
        // `pinCanvas` mounts every canvas at the very back, which would put the incoming one under
        // the outgoing one for the length of a transition and hide whatever it plays on the way
        // in. Order the pair here instead, both still below every piece of chrome.
        if let outgoing {
            container.addSubview(c.view, positioned: .above, relativeTo: outgoing)
        }
        mountedCanvas = c.view
        restoreFocusToActive()  // a shown float keeps focus; it rides the tab switch
        renderDock()  // dock mirrors the newly-active tab's overlay state

        switch transition {
        case .instant:
            outgoing?.removeFromSuperview()
            return true
        case .slide(let edge):
            container.layoutSubtreeIfNeeded()  // resolve the canvas width before offsetting it
            let dx = edge == .fromRight ? container.bounds.width : -container.bounds.width
            // Reduce Motion collapses the slide, and `slideSwap` then runs its completion inline,
            // before this call returns. `onLanded` must not fire from in there, so that case is
            // reported back to the caller instead of announced early.
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
        // Mount at the BACK of the container, not "just below the tab bar": a canvas is the
        // backdrop every piece of window-level chrome sits on. Stacking it relative to `tabBar`
        // would land it above a float card, which a tab change dismisses and which spends that
        // moment springing out, so the incoming canvas would swallow the dismiss.
        if canvas.superview === container {
            container.addSubview(canvas, positioned: .below, relativeTo: nil)  // just restack
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

    /// Dismiss a shown tool float because the tab underneath is about to change, the same rule
    /// every modal card follows.
    ///
    /// A float is modal over the window, so letting the tab change behind it would leave someone
    /// typing into a card while the world they can't see moved. Nothing is lost: the registry is
    /// window-level, so a persistent float keeps running and reopens on the same instance.
    private func closeFloatForTabChange() { floats.close() }

    /// Hand keyboard focus back to whatever should hold it: the shown tool float, else the active
    /// tab's focused panel. The float wins because it's modal over the window — without this, a
    /// tab switch or a dismissed modal card would steal first responder to the pane sitting behind
    /// a still-visible card.
    private func restoreFocusToActive() {
        if floats.isOpen { floats.refocus() } else { activeController?.restoreUnifiedFocus() }
    }

    /// Host a tool-float card at window level, over the active tab's tile region. Hosted on
    /// `container` rather than inside the active tab, because a tab-hosted card unmounts with its
    /// tab and a float has to survive a tab switch.
    ///
    /// The constraints reproduce the tile region exactly, because `SurfaceFloatOverlay` resolves
    /// its fractions against its OWN bounds: the host rect *is* the geometry, so a naive pin to
    /// `container` would resize every float and slide it over the tab bar.
    ///
    /// Inserted below `tabBar`, which keeps it under the toast stack. The ⌘W guard toast fires
    /// precisely while a card is up, and a card stacked over the toasts would swallow it.
    private func presentWindowFloat(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .below, relativeTo: tabBar)
        let gutter = ChromeMetrics.windowGutter
        // Retained so a live `window-gutter` edit can re-inset an OPEN card. The tab-hosted path
        // this replaced got that for free (it pinned to `content`, whose own gutter constraints
        // `reapplyChromeLayout()` updates); baking the constant in and walking away would leave a
        // shown float at the old inset while every tab behind it resized (the bug class).
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

    /// Host a modal card at window level, over the active tab's tile region, at the FRONT of the
    /// stack and above the toasts. A card owns the keyboard and dims the tile behind it, so a
    /// passive notice landing on top reads as broken. Floats sit below the toasts instead, because
    /// the ⌘W guard toast fires while a float is open and is telling you to close it.
    ///
    /// The rect is the tile region flattened, so the dimming backdrop covers exactly that region:
    /// gutter on three sides, `ChromeMetrics.topInset` on top. Taking the gutter for the top runs
    /// the card under the window buttons. The insets are retained so a live gutter edit re-insets
    /// an open card.
    private func presentWindowModal(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)  // front of the stack, so it clears the toasts
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

    /// Re-inset the shown float card after a `window-gutter` change. Constraints belonging to a
    /// dismissed card die with it, so a stale entry here is harmless — it's replaced on next open.
    private func reapplyFloatLayout() {
        guard let floatGutter else { return }
        let gutter = ChromeMetrics.windowGutter
        floatGutter.leading.constant = gutter
        floatGutter.trailing.constant = -gutter
        floatGutter.top.constant = ChromeMetrics.topInset  // the tile's top carries traffic-light clearance
        floatGutter.bottom.constant = -gutter
    }

    /// The same re-inset for an open modal card. Window-hosted, so it does not inherit
    /// the tile's gutter: without this a live `window-gutter` edit resizes every tab behind an open
    /// card and leaves the card itself at the old inset.
    private func reapplyModalLayout() {
        guard let modalGutter else { return }
        let gutter = ChromeMetrics.windowGutter
        modalGutter.leading.constant = gutter
        modalGutter.trailing.constant = -gutter
        modalGutter.top.constant = ChromeMetrics.topInset  // the tile's top carries traffic-light clearance
        modalGutter.bottom.constant = -gutter
    }

    // MARK: tab ops

    private func newTab() {
        cancelConfirm()  // the tab-bar "+" is reachable by mouse while a confirm is up
        addTab(cwd: ShellLaunch.newSessionCWD(focused: activeController?.focusedCWD), pinnedTitle: nil)
    }

    /// Append a new tab with an explicit cwd and optional pinned title. The `⌘P` picker
    /// passes a `Workspace` (its path + title + open recipe); plain `⌘t` passes the inherited
    /// cwd, no pin, and no workspace (a bare shell).
    private func addTab(cwd: URL?, pinnedTitle: String?, workspace: Workspace? = nil) {
        Log.info("tab opened", category: .tabs)
        closeModal()  // the "+" button is reachable while a palette is up
        closeFloatForTabChange()
        let id = mintTabID()
        tabs.add(id)
        // A new tab is appended at the right end, so it enters from the right — the same rule
        // `select(_:)` follows for a later tab, so create and switch read as one motion.
        installController(
            id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace,
            transition: .slide(from: .fromRight))
    }

    /// Replace the active tab's controller in place (same tab id/slot) with a fresh session in
    /// `cwd`, pinned to `pinnedTitle` and running `workspace`'s recipe. Used by `⌘P` + Shift+Enter.
    private func replaceActiveTab(cwd: URL, pinnedTitle: String?, workspace: Workspace?) {
        closeFloatForTabChange()  // swapping the tab out from under a modal card is the same bug
        let id = tabs.activeID
        let old = controllers[id]
        if mountedCanvas === old?.view {
            old?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        old?.shutdown()  // terminate the replaced tab's shells — never leak them
        // Load-bearing, because the tab keeps its id: without this the replacement session inherits
        // the previous one's Scratch shell, cwd and scrollback and all.
        floats.shutdownScope(id)
        // The tab stays put — same id, same slot — and its outgoing canvas is already gone with
        // the shells it was showing, so there is nothing to transition from: the replacement
        // appears in place and the workspace's own drawer slides carry the motion.
        installController(
            id: id, cwd: cwd, pinnedTitle: pinnedTitle, workspace: workspace, transition: .instant)
    }

    /// Build, wire, mount, and start a controller for `id`, applying the workspace's open recipe
    /// when one is given. Shared by new-tab and replace-tab, which mount with different
    /// transitions.
    ///
    /// The recipe is **staged behind the canvas's motion**, so a new tab arrives and then unfolds
    /// its drawers: a drawer travelling the same direction as the canvas it rides in on has no
    /// readable motion of its own.
    private func installController(
        id: TabID, cwd: URL?, pinnedTitle: String?, workspace: Workspace?, transition: MountTransition
    ) {
        let c = makeController(cwd: cwd, workspace: workspace)
        c.pinnedTitle = pinnedTitle
        controllers[id] = c
        titles[id] = c.title
        wire(c, id: id)
        let landed = mount(transition) { [weak self, weak c] in
            // Closing or replacing the tab inside the transition must not apply a recipe to the
            // controller that moment tore down (`closeTab` clears the entry, so this covers both).
            guard let self, let c, let workspace, self.controllers[id] === c else { return }
            c.applyRecipe(workspace)
            // Switching tabs inside the slide leaves this one in the background. Its drawers are
            // still its own layout and open regardless, but the recipe's focus belongs to the tab
            // the user is looking at, not the one that finished arriving behind it.
            if self.tabs.activeID != id { self.restoreFocusToActive() }
        }
        c.start()
        // A mount that had already landed by the time it returned has no completion to wait for,
        // so the recipe runs here: after `start()`, the order it has always run in.
        if landed, let workspace { c.applyRecipe(workspace) }
        renderTabBar()
    }

    private func select(_ id: TabID, slideFrom: SlideEdge? = nil) {
        // Load-bearing: a card is window-hosted, so nothing unmounts it implicitly and
        // it would otherwise stay open over the tab you land on.
        closeModal()
        guard tabs.order.contains(id), id != tabs.activeID else { return }
        Log.info("tab switched", category: .tabs)
        closeFloatForTabChange()
        clearAttention(id)
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

    /// Shift the active tab one slot along the bar. The numbers, tooltips and toast keycaps are
    /// all derived from `tabs.order` at render time, so re-rendering is the whole update.
    private func moveActiveTab(_ delta: Int) {
        guard tabs.move(tabs.activeID, by: delta) else { return }
        Log.info("tab moved", category: .tabs)
        renderTabBar()
    }

    /// Open the rename card for `id`. Takes the single modal slot, so whatever else is up closes.
    private func openRenameTab(_ id: TabID) {
        guard let controller = controllers[id] else { return }
        // Double-clicking the ACTIVE chip never reaches `select`'s own call: it returns early on
        // the id already being active, so a pending Close confirm would sit under the card.
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

    /// Commit a rename. An empty name clears the pin, so the tab goes back to its live cwd title.
    /// Rendered here rather than left to the 1.5s title poll, which would look like a stall.
    private func renameTab(_ id: TabID, to name: String) {
        guard let controller = controllers[id] else { return }
        controller.pinnedTitle = name.isEmpty ? nil : name
        titles[id] = controller.title
        renderTabBar()
    }

    /// Close a specific tab: terminate its shells, detach its canvas, and cascade to
    /// closing the window when it was the last tab.
    private func closeTab(_ id: TabID) {
        Log.info("tab closed", category: .tabs)
        closeModal()  // the "×" button is reachable while a palette is up
        closeFloatForTabChange()
        cancelConfirm()  // a middle-click close voids a pending confirm on another tab
        let survived = tabs.close(id)
        let controller = controllers[id]
        if mountedCanvas === controller?.view {
            controller?.view.removeFromSuperview()
            mountedCanvas = nil
        }
        controller?.shutdown()  // terminate the tab's shells — never leak them
        floats.shutdownScope(id)  // and its Scratch, which is the tab's the way its drawers are
        controllers[id] = nil
        titles[id] = nil
        clearAttention(id)
        if !survived { window.close(); return }  // last tab → close window → windowWillClose tears down
        // Closing the active tab promotes a neighbor to active; if it was flagged waiting, clear
        // it now — a foreground tab is never "waiting" (and its toast's Switch would be a no-op).
        clearAttention(tabs.activeID)
        mount(.instant)
        renderTabBar()
    }

    // MARK: modal cards (⌘P picker / ⌘⇧P palette / Add-Workspace form)

    /// Present a modal card over the active tab: mount it, store it in the single slot, focus its
    /// input, and spring it in. One path for all three cards. No-op if there's no active tab.
    private func presentModal(_ overlay: ModalOverlay, kind: ModalKind) {
        guard activeController != nil else { return }
        endModes()  // the card takes the keyboard; see the float's `yieldFocus`
        // Anything else still on its way in would otherwise land on top of this card a moment from
        // now, leaving two modal surfaces stacked and the keyboard aimed at the wrong one: a float
        // still resolving its repo root, or a card still reading the config it renders from. A
        // surface already SHOWN is a different case, handled by the chord gate.
        floats.cancelPendingOpen()
        pendingModal = nil
        presentWindowModal(overlay)
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
        pendingModal = nil  // a card still loading is closed by never being presented
        guard let overlay = modal?.overlay else { return }
        modal = nil
        modalGutter = nil  // the constraints die with the view; don't re-inset a card on its way out
        overlay.animateOut { overlay.removeFromSuperview() }
        restoreFocusToActive()
        renderDock()
    }

    /// Toggle the workspace picker. Reads the `workspaces` file fresh on each open, so hand-edits
    /// appear without a relaunch.
    ///
    /// The read is off the main thread, and the card is built once the workspaces are in hand
    /// rather than presented empty and filled, since a card that springs in and resizes a frame
    /// later reads as a flash. A slow disk costs a late card, not an unresponsive app.
    private func toggleRepoPicker() {
        if modal?.kind == .repoPicker || pendingModal == .repoPicker { closeModal(); return }
        pendingModal = .repoPicker
        ConfigLoader.loadWorkspaces { [weak self] workspaces in
            guard let self, self.pendingModal == .repoPicker else { return }
            self.pendingModal = nil
            let picker = RepoPickerOverlay(
                entries: workspaces,
                background: Theme.current.chrome.background.nsColor,
                onChoose: { [weak self] ws, replace in self?.openWorkspace(ws, replaceCurrentTab: replace) },
                onAddWorkspace: { [weak self] in self?.openAddWorkspaceForm() },
                onDismiss: { [weak self] in self?.closeModal() }
            )
            self.presentModal(picker, kind: .repoPicker)
        }
    }

    /// Toggle the command palette (⌘⇧P). Builds the catalog fresh (its tab-select entries track
    /// the live tab count). Pressing ⌘⇧P while it's up closes it.
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

    /// Open the Add-Workspace form from the picker's ＋ row, seeded with the current titles for
    /// inline collision checks. The picker is still up when ＋ fires, so close it first.
    ///
    /// Waits for the load rather than presenting without it: the collision check has to be right
    /// from the first keystroke, and a form seeded with half the titles would accept a duplicate.
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

    /// Open the "Report an Issue" composer (Help menu + Settings). Non-private: `AppDelegate` routes
    /// the Help-menu item here, and the Settings nav button calls it too. It's terminal, so opening
    /// the GitHub issue or cancelling just closes back to the terminal (Settings doesn't reopen).
    /// Reusing the single modal slot means opening it from Settings dismisses Settings first.
    func openReportIssue() {
        // Reached from the Help menu as well as a chord, and the menu bypasses the `isConfirmOpen`
        // gate in `handle`. A card would paint over a pending destructive confirm and leave it both
        // hidden and unanswerable, so the confirm wins the same way it does for a chord.
        if isConfirmOpen { return }
        if modal?.kind == .reportIssue { closeModal(); return }
        if modal != nil { closeModal() }  // single slot — dismiss whatever's up (e.g. Settings) first
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

    /// Which section the Settings card opens on. `.tools` / `.workspaces` are used when a sub-form
    /// (tool-float or workspace editor) hands back to the section it was launched from; the
    /// per-section cases are where the config-diagnostics toast lands.
    private enum SettingsLanding { case top, tools, workspaces, terminal, appearance, general, shortcuts }

    /// The Settings section that owns a diagnostic's subject — where the config-diagnostics toast's
    /// "Open Settings" button lands. Keybind problems go to Shortcuts, a dropped float to Tools, and a
    /// scalar/enum key to whichever section holds its row.
    private static func landing(for scope: ConfigDiagnostic.Scope) -> SettingsLanding {
        switch scope {
        case .keybind, .keybindLine: return .shortcuts
        case .toolFloat, .toolFloatField: return .tools
        case .setting(let key): return landing(forSettingKey: key)
        }
    }

    /// The one place mapping a config key to its Settings section. Mirrors what each
    /// `SettingsFormSection` subclass registers in `populate()`; a key with no form row (e.g.
    /// `debug`) or an unrecognized one lands on the nav.
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

    /// The `navTitle` a landing resolves to (nil = the nav / first section) — the single source both
    /// `openSettings` and the diagnostics-landing test read, so they can't drift.
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
        /// Test hook: the Settings section (by `navTitle`, nil = nav) the config-diagnostics toast
        /// lands on for a given scope. Resolves the private `SettingsLanding` to the observable title
        /// so a test can pin the scope→section map without touching internals.
        static func settingsLandingNavTitleForTesting(for scope: ConfigDiagnostic.Scope) -> String? {
            navTitle(for: landing(for: scope))
        }
    #endif

    /// Open the Settings card. Built fresh each open so every section reads live config values.
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
        // Sorted by nav title so the nav reads alphabetically and stays ordered as sections are
        // added — the array order is the on-screen order.
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
        // Opening the composer dismisses Settings first (single modal slot); it's terminal and
        // doesn't reopen Settings on close.
        overlay.onReportIssue = { [weak self] in self?.openReportIssue() }
        presentModal(overlay, kind: .settings)
    }

    /// Open Settings on the section that owns `scope` — the config-diagnostics toast's "Open Settings"
    /// action. Always opens (re-opening on the target if Settings is already up), never the
    /// ⌘, toggle: someone acting on the toast wants the section, not to close a card they just opened.
    func openSettings(for scope: ConfigDiagnostic.Scope) {
        if modal != nil { closeModal() }  // single slot: replace whatever's up, then land on the section
        openSettings(landing: Self.landing(for: scope))
    }

    /// Present the config-diagnostics reload notice as a sticky, actionable toast: a primary
    /// "Open Settings" that lands on the first problem's section, plus a Dismiss. Non-modal — it arms
    /// no key equivalents, so it never steals input from the terminal. `landingScope` is the
    /// scope the primary button opens; the caller passes the first diagnostic's.
    func showConfigDiagnosticsToast(_ content: ToastContent, landingScope: ConfigDiagnostic.Scope) {
        // `weak` breaks the retain cycle the strong-capture idiom would form: the toast retains its
        // buttons, each button retains its `onTap`, and these closures reference the toast — so a
        // strong capture would leak every sticky toast past dismissal. The presenter's stack keeps the
        // toast alive until dismissed; the closures only need to reach it, not own it.
        weak var toast: ToastView?
        // Dismiss on the left, primary on the right — the confirm-dialog convention (see the
        // waiting-toast).
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
        // Its Dismiss writes nothing, so a dismiss chord can run the same closure safely.
        shown.onClose = { [weak self, weak shown] in shown.map { self?.toasts.dismiss($0) } }
        toast = shown
        configDiagnosticsToast = shown
    }

    /// The config-problems notice this window is showing, if any. Weak: the presenter's stack owns
    /// it, and a user dismissal must leave nothing to retract.
    private weak var configDiagnosticsToast: ToastView?

    /// A weak handle to a card, so the array below can hold several without owning any. Swift has no
    /// weak array element, and a strong one here would keep a closed card alive for the window's
    /// lifetime. Local on purpose: one array needs this, not the app.
    private struct WeakToast {
        weak var value: ToastView?
    }

    /// The conflict cards this window is showing, each paired with what it is about. Held weakly for
    /// the same reason the single notice above is: the presenter's stack owns them, and a card the
    /// user closed must leave nothing behind to retract.
    private var conflictToasts: [(conflict: KeybindConflict, toast: WeakToast)] = []

    /// One sticky card per outstanding chord conflict, each carrying the two answers. One per
    /// conflict rather than a list, because each is a separate decision and one Accept must not
    /// settle three lines.
    ///
    /// Revert is offered only when a `keybind =` line took the chord: a float's `key:` is
    /// required, so there is nothing to back out to.
    func showConflictToasts(_ conflicts: [KeybindConflict]) {
        // Reconcile rather than rebuild. Answering a card writes, which reloads, which lands back
        // here with one fewer conflict: tearing the stack down and re-showing it sprang every
        // surviving card out and a new one in, so the remaining cards visibly dropped and settled.
        // A card the user did not touch should not move.
        var kept: [(conflict: KeybindConflict, toast: WeakToast)] = []
        for entry in conflictToasts {
            guard let toast = entry.toast.value else { continue }  // already closed by hand
            if conflicts.contains(entry.conflict) {
                kept.append(entry)
            } else {
                toasts.dismiss(toast)
            }
        }
        conflictToasts = kept
        for conflict in conflicts where !kept.contains(where: { $0.conflict == conflict }) {
            // `weak toast` for the reason the diagnostics notice uses it: the toast retains its
            // buttons, each button retains its `onTap`, and these closures reach back to the toast.
            weak var toast: ToastView?
            // Take the card down only once the write lands. Dismissing first showed the card sliding
            // away for a write that threw, so an unwritable config read as a successful answer and
            // the conflict came back at the next launch with nothing having said why.
            let answer = { [weak self] (resolve: (KeybindConflict) -> Bool) in
                guard resolve(conflict) else { return }  // the resolver logged; the card stays, so it can be retried
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
            // The third exit: close it, change nothing, meet it again next launch. Answering is a
            // write and putting a card away must not be one.
            //
            // `weak toast`, not `shown`: this closure is stored ON the card, so a strong capture
            // cycles. A leaked card stays non-nil, survives the reconcile, and the conflict never
            // comes back.
            shown.onClose = { [weak self] in toast.map { self?.toasts.dismiss($0) } }
            toast = shown
            conflictToasts.append((conflict, WeakToast(value: shown)))
        }
    }

    /// Take down every conflict card this window is showing. Closing one by hand leaves its box
    /// empty rather than removed, so the array is swept here rather than kept exact.
    func dismissConflictToasts() {
        conflictToasts.compactMap(\.toast.value).forEach { toasts.dismiss($0) }
        conflictToasts = []
    }

    /// Deliver a conflict card set to `keyWindow`, replacing any predecessor across every window.
    /// The static shape and the sweep-then-deliver order mirror `deliverConfigDiagnosticsNotice`,
    /// and for the same reasons: reachable from a test, and sweeping before the target resolves
    /// would take accurate cards down and put nothing back.
    static func deliverConflictNotices(
        _ conflicts: [KeybindConflict], to keyWindow: WindowController?,
        replacingAcross windows: [WindowController]
    ) -> Bool {
        guard let keyWindow else { return false }
        // Every window but the target, which reconciles its own rather than being swept: sweeping it
        // first would rebuild cards that did not change and make the stack jump.
        windows.filter { $0 !== keyWindow }.forEach { $0.dismissConflictToasts() }
        keyWindow.showConflictToasts(conflicts)
        return true
    }

    /// Deliver the config-problems notice to `keyWindow`, replacing any predecessor across every
    /// window. Returns whether a window took it; `false` leaves the notice already up untouched so
    /// `ConfigApplier` can retry on the next reload.
    ///
    /// Sweeps *every* window, not just the target, because the outstanding notice went to whoever
    /// was key at the time. Sweeping before the key window resolves would take an accurate notice
    /// down and put nothing back.
    static func deliverConfigDiagnosticsNotice(
        _ content: ToastContent, landingScope: ConfigDiagnostic.Scope,
        to keyWindow: WindowController?, replacingAcross windows: [WindowController]
    ) -> Bool {
        guard let keyWindow else { return false }
        windows.forEach { $0.dismissConfigDiagnosticsToast() }
        keyWindow.showConfigDiagnosticsToast(content, landingScope: landingScope)
        return true
    }

    /// Retract the config-problems notice. It's sticky and states what is wrong *now*, so a reload
    /// that resolves the problems has to take it down: nothing else does, and a warning that
    /// outlives the fix that made it false is worse than no warning. Reads `builtToasts` rather
    /// than `toasts` so retracting can never construct the presenter (see `hasBuiltToastsForTesting`).
    func dismissConfigDiagnosticsToast() {
        guard let toast = configDiagnosticsToast else { return }
        configDiagnosticsToast = nil
        builtToasts?.dismiss(toast)
    }

    /// Where the tool-float form hands back to when it closes. Launched from Settings → Tools the card
    /// has to come back, or saving a float drops the user on a bare terminal from a place they were
    /// mid-task in. Launched from ⌘P there is nothing behind it to restore.
    private enum ToolFormReturn { case settings, none }

    /// Where a form opened by the `new_tool_float` chord hands back to: Settings when the gate just
    /// closed it, and whatever the previous form was returning to when the gate closed one of
    /// those. Anything else has nothing to restore.
    private func toolFormReturnForNewTool() -> ToolFormReturn {
        switch closingModalKind {
        case .settings: return .settings
        case .toolFloatForm: return toolFormReturn ?? .none
        default: return .none
        }
    }

    /// Open the tool-float add / edit form (`nil` adds, a value edits).
    ///
    /// `existingIDs` is the slug of every *other* float, which the form rejects a colliding title
    /// against; subtracting the edited float's own id is what lets a re-save keep its title. The
    /// built-ins are in there too: the parser refuses a line claiming one, so without this the form
    /// would write a line that vanishes on the next reload.
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

    /// Take the tool-float form down, restoring Settings → Tools when that is where it came from.
    private func finishToolFloatForm(_ returnTo: ToolFormReturn) {
        toolFormReturn = nil
        switch returnTo {
        case .settings: reopenSettingsOnTools()
        case .none: closeModal()
        }
    }

    /// Persist a new float order (`floats` arrives in the user's intended order), then reload so the
    /// dock reorders live behind the open Settings card.
    ///
    /// Unlike add / edit / delete this doesn't `reopenSettingsOnTools()` — the card is already open and
    /// rebuilding it would throw away the user's place in the list mid-⌥↓.
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
        // Same as the add form: the collision check needs the whole title set before the first
        // keystroke, so the card waits on the load rather than presenting half-seeded.
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
                onSubmit: { [weak self] built in self?.submitWorkspace(built, replacing: originalTitle) },
                onCancel: { [weak self] in self?.reopenSettingsOnWorkspaces() },
                onDelete: workspace.map { existing in { [weak self] in self?.deleteWorkspace(existing) } }
            )
            self.presentModal(form, kind: .workspaceForm)
        }
    }

    /// Persist a workspace edited / added from Settings, then hand back to Settings → Workspaces (the
    /// ⌘P picker reads the file fresh on each open, so no reload is needed for it to reflect this).
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

    /// Exchange two workspaces' positions in the `workspaces` file, reporting whether the write
    /// landed so the list only re-renders on a file that really changed. Unlike add / edit / delete
    /// this doesn't reopen Settings — the card is already open and rebuilding it would throw away the
    /// user's place in the list mid-⌥↓. Nothing to reload either: the ⌘P picker re-reads the file
    /// every time it opens.
    private func reorderWorkspaces(_ moved: Workspace, with neighbour: Workspace) -> Bool {
        do {
            // False means a title wasn't in the file: the list is stale, so re-rendering it would
            // show an order the file never had. Silent rather than a toast — the file changed under
            // the card (a hand-edit, another window), which isn't a failure to report.
            return try WorkspacesWriter.swap(moved.title, with: neighbour.title)
        } catch {
            toasts.show(
                ToastContent(
                    variant: .warning, title: "Couldn't Reorder Workspaces",
                    message: "Failed to update the workspaces file: \(error.localizedDescription)"))
            return false
        }
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
        // A confirm answers with Return and Esc, and both are dispatched after the local key
        // monitor. Left up, a mode swallows the Return and reads the Esc as its own exit, so the
        // confirm could only be answered with the mouse. `closeModal` above does not cover this:
        // it returns early when no card is open, which is the ⌘W case exactly.
        endModes()
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
        guard replaceCurrentTab else {
            addTab(cwd: ws.path, pinnedTitle: ws.title, workspace: ws)  // ⏎: new tab, destroys nothing
            return
        }
        // ⇧⏎ replaces the current tab, terminating every pane and drawer in it, plus its Scratch —
        // `replaceActiveTab` reaches `shutdownScope`. That silent clobber gets a confirm when the
        // tab has live work; an idle tab is replaced outright. Window-scoped floats survive the
        // replace, so they still don't count.
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

    // MARK: chord routing

    func handle(_ chord: KeyInterceptor.ReservedChord) {
        guard !tabs.order.isEmpty else { return }  // window tearing down after last tab closed
        // Written by the card gate below and read by the action that opens in its place, both later in
        // this call. Cleared here so a value can never survive into a later keypress and hand a form
        // back to a card that closed minutes ago.
        closingModalKind = nil
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
            case .toggleRepoPicker, .toggleCommandPalette, .openSettings, .toggleToolFloat, .reportIssue,
                .newTool:
                closingModalKind = modal.kind  // the surface opening below may have to hand back to it
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
                floats.close()  // close it, then fall through to open the other
            case .toggleToolFloat, .newTab, .newWindow, .selectTab, .prevTab, .nextTab,
                .moveTabLeft, .moveTabRight, .fillScreen,
                .increaseFontSize, .decreaseFontSize, .resetFontSize, .selectAll,
                // Reading the card's own buffer. `modeTarget` resolves the shown float ahead of the
                // panel behind it, so all of these act on the terminal you are looking at.
                .toggleScrollMode, .toggleSearch, .searchSelection, .findNext, .findPrevious,
                .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown, .scrollToSelection,
                .jumpToPreviousPrompt, .jumpToNextPrompt, .pasteSelection, .clearScreen,
                .writeScreenFile, .copyScreenFilePath, .openScreenFile,
                // Notices stack over an open float — the ⌘W-over-a-float notice is itself one — so
                // swallowing these would kill them exactly when the pile is growing.
                .dismissToast, .dismissAllToasts:
                // Cross-tab/window chords still act; Fill Screen is window-level. Font size is
                // app-wide and the float itself is a terminal surface, so resizing over an open
                // float resizes the float too: blocking it here would be the bug again.
                // Select All is here because Edit > Select All reaches the float from the responder
                // chain, and a rebound chord swallowed here would disagree with the menu.
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
            // App-global (window manager / config reload / update check / font size). The keyboard
            // path routes these in AppDelegate before handle; a palette pick lands here, so forward
            // it back. Font size is app-global on purpose: scoping it to a window
            // would leave the same "didn't propagate" bug one level up.
            onAppGlobalCommand?(chord)
        case .toggleBottomDrawer:
            Log.info("bottom drawer toggled", category: .drawers)
            active?.toggleBottomDrawer()
        case .toggleRightDrawer:
            Log.info("right drawer toggled", category: .drawers)
            active?.toggleRightDrawer()
        case .toggleZoom:
            Log.info("zoom toggled", category: .panes)
            // The zoom takes first responder off the find field without the bar hearing it, leaving
            // it up with a dead caret. A scroll mode the reader opened is untouched: see `teardown`.
            search.end()
            active?.toggleZoom()
            // A multi-pane zoom reparents the canvas, so the pane takes first responder again and
            // paints a live cursor back over a mode that is still up. Re-assert the mode's render.
            updateModeHandler()
        // `builtToasts`, not `toasts`: dismissing must never be what constructs the stack.
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
        // Negative is up the buffer, toward older output, the same sign every other scroll takes.
        case .jumpToPreviousPrompt: scrollFocusedPane(.prompt(-1))
        case .jumpToNextPrompt: scrollFocusedPane(.prompt(1))
        case .clearScreen: modeTarget?.surface.clearScreen()
        // The Edit menu serves ⌘A; this is whatever chord a config rebinds the action to, routed
        // through the same endpoint so the two spellings cannot drift.
        case .selectAll: selectAll(nil)
        case .writeScreenFile: modeTarget?.surface.writeScreenToFile(.paste)
        case .copyScreenFilePath: modeTarget?.surface.writeScreenToFile(.copy)
        case .openScreenFile: modeTarget?.surface.writeScreenToFile(.open)
        case .pasteSelection: pasteSelection()
        case .fillScreen: toggleFillScreen()
        case .toggleToolFloat(let id):
            // A float is modal too, so it calls off a card that's still loading — otherwise the card
            // lands on top of it a beat later. `presentModal` is the mirror of this.
            pendingModal = nil
            if let spec = ToolFloatCatalog.byID(id) { floats.toggle(spec) }
        case .toggleRepoPicker: toggleRepoPicker()
        case .toggleCommandPalette: toggleCommandPalette()
        case .openSettings: openSettings()
        case .reportIssue: openReportIssue()
        // Settings was the only way to create a tool float; this is the same form, reached from ⌘P.
        // The chord is bindable, so it can be pressed with Settings already up: the gate above closed
        // that card, and cancelling has to put it back rather than drop the user on a bare terminal.
        case .newTool: openToolFloatForm(editing: nil, returnTo: toolFormReturnForNewTool())
        }
    }

    /// The window frame before Fill Screen grew it, so a second ⌘⏎ restores the exact size
    /// and position. Nil means the window is not currently filled.
    private var preFillFrame: NSRect?

    /// Toggle the window between its current size and the screen's visible frame (the desktop
    /// minus the menu bar and Dock). This is NOT native macOS fullscreen — no space switch, the
    /// menu bar stays — just a "fill the desktop" maximize with a restore on the second press.
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

    /// Number of open tabs in this window (for the quit tally).
    var tabCount: Int { tabs.order.count }

    /// Bring `id` to the front (banner-click routing). Public wrapper over the private `select`.
    func selectTab(_ id: TabID) { select(id) }

    /// The app regained focus: this window's frontmost (active) tab is now on screen, so drop any OS
    /// banner pushed for it while unfocused. `clearAttention` never fires for the active tab (it's never
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

    /// ⌘W: close silently when there's nothing to lose, otherwise confirm first.
    /// - A focused drawer closes like `exit`, just the drawer, and confirms only when busy.
    /// - A non-last pane confirms only if it's busy.
    /// - The last pane closes the tab, so the confirm is titled "Close Tab" and fires only when
    ///   the tab has live work.
    private func requestClosePane() {
        guard let active = activeController else { return }

        // A focused drawer is its own close target: ⌘W kills that drawer (like `exit`), never
        // the tab. Busy → confirm; idle → close silently, exactly like an empty second pane.
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
        // ⌘W on the last pane closes the tab; on the last tab that also closes the window.
        let closesWindow = lastPane && tabs.order.count == 1

        // Weighs exactly the live work THIS ⌘W would stop. Panes, drawers and the tab's own floats
        // count once it's the last pane, since that close IS a tab close and `shutdownScope` takes
        // the tab-scoped ones down with it. Window-scoped floats survive a tab close, so they count
        // only when ⌘W also closes the window, which is where a dismissed persistent tool has no
        // on-screen trace and would otherwise die unannounced.
        let needsConfirm =
            busy
            || (lastPane && (active.hasBusyDrawer || floats.hasBusyInScope(tabs.activeID)))
            || (closesWindow && floats.hasBusy)
        guard needsConfirm else {
            // Nothing to lose → close now, cascading to the tab when it was the last pane.
            if active.closeFocused() == false { closeTab(tabs.activeID) }
            return
        }

        // Name the real effect: the last pane's close IS a tab close.
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

    // MARK: the Edit menu's verbs, routed to the shown tool float, else the active tab's controller

    // The terminal end of the responder chain for Copy, Paste and Select All. Anything with a
    // caret is above this and never lets them reach the window. Cut, Undo and Redo are the field's
    // alone, so nothing here answers them and they grey out over a pane.
    //
    // A shown float is modal and owns the verbs, gated on visibility rather than the registry
    // because a persistent float's surface outlives its card. A modal card swallows instead of
    // acting: it is mid-question, so copying the buffer behind it answers nothing.
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
        // `focusedScrollTarget` already resolves a focused drawer as well as a pane, so this needs
        // no drawer branch of its own the way copy and paste do.
        if floats.isOpen {
            floats.selectAllInSurface(sender)
        } else {
            activeController?.focusedScrollTarget?.surface.selectAll()
        }
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
        // Focus moving also ends both modes: they target one panel, and a header or a find bar
        // still up over the panel you just left points at a buffer you are no longer reading.
        c.onFocusChanged = { [weak self] in
            self?.cancelConfirm()
            self?.endModes()
        }
        c.onSurfaceEvent = { [weak self] surface, event in self?.report(surface, event) }
        c.onNotification = { [weak self] n in self?.agentNotified(id: id, notification: n) }
        c.onCommandFinished = { [weak self] result in self?.commandFinished(id: id, result: result) }
    }

    /// A tool float's agent wants attention. Floats are window-level, so unlike a pane or drawer
    /// this has no owning tab: it gets the OS banner but not the in-app rose flag, which is a
    /// per-tab signal that would otherwise point at a surface that isn't the source.
    /// `owner` is the tab a tab-scoped float belongs to, which is where the banner's click has to
    /// land: a hidden Scratch that asks for input is usually NOT in the tab that happens to be up,
    /// and routing to the active tab would send the user somewhere the prompt isn't. A window
    /// float belongs to no tab, so it keeps falling back to the active one.
    private func floatNotified(
        _ notification: TerminalNotification, from spec: ToolFloat, owner: TabID?
    ) {
        // The notification arrives off the terminal's read path; only touch the UI on main.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tabs.order.isEmpty,
                AgentNotifier.shouldPushNotification(
                    appActive: NSApp.isActive, enabled: GeneralConfig.current.agentNotifications)
            else { return }
            // The owner may have closed between the post and this hop, and a banner pointing at a
            // tab that is gone opens nothing.
            let target = owner.flatMap { self.tabs.order.contains($0) ? $0 : nil } ?? self.tabs.activeID
            AgentNotifier.shared.notify(
                windowID: self.windowID, tabID: target, title: spec.title,
                body: notification.body.isEmpty ? notification.title : notification.body)
        }
    }

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
            let wasWaiting = self.attentionStates[id] == .waiting
            self.presentWaitingToast(for: id, message: message)
            if !wasWaiting { self.renderTabBar() }  // first flag → recolor the number
        }
    }

    /// A long command in a background tab completed. The terminal output is the feedback for the
    /// tab already on screen; short commands are routine shell traffic and stay quiet. An agent
    /// notification is actionable and therefore keeps priority over a later completion event.
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

    /// Show (or replace) the persistent, non-modal attention toast for a background tab. The
    /// title is the tab's name. It answers only through its buttons — "Switch" jumps to the
    /// tab, "Dismiss" clears the notice — and visiting the tab any other way clears it too.
    private func presentWaitingToast(for id: TabID, message: String) {
        if let old = attentionToasts[id] { toasts.dismiss(old) }
        let content = ToastContent(
            variant: .info, title: titles[id] ?? "shell", message: message, icon: "bell.fill")
        // Match the confirm-dialog convention: muted secondary action on the left, primary on
        // the right (Dismiss, then Switch).
        let actions = [
            ToastAction(title: "Dismiss", kind: .cancel) { [weak self] in
                guard let self else { return }
                self.clearAttention(id)
                self.renderTabBar()  // "Dismiss" also clears the tab attention marker
            },
            // ⌘N already switches while this toast is up (it's non-modal and arms no key
            // equivalents) — the keycap just says so. Resolved lazily, never baked.
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

    /// Mount an attention card for `id` and give it the two hooks the raw presenter can't know
    /// about: `onClose` is what a dismiss chord runs (the same clearing its Dismiss button does),
    /// and `onDismissed` drops this window's handle so an auto-dismissed card isn't left in
    /// `attentionToasts` as a detached view the next reader trusts.
    ///
    /// A card that clears itself does NOT clear the tab's number: the notice is still unseen, and
    /// only visiting the tab or pressing Dismiss says otherwise.
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
            // Only if it is still the current card: a replacement may already have taken the slot.
            guard let self, let toast, self.attentionToasts[id] === toast else { return }
            self.attentionToasts[id] = nil
        }
        return toast
    }

    /// A pane's surface failed to start: show a sticky, non-modal notice offering to retry the
    /// launch or close the dead pane. Each button starts the toast's (asynchronous) dismiss and
    /// then runs its action; a failed retry re-fires this path with a fresh toast. Both roles are
    /// theme-driven via the `.warning` variant, so no color is hardcoded.
    private func presentSurfaceFailureToast(retry: @escaping () -> Void, close: @escaping () -> Void) {
        let content = ToastContent(
            variant: .warning, title: "Terminal Didn't Start",
            message: "The terminal surface failed to launch.")
        // `weak` breaks the retain cycle toast → button → onTap → toast that would otherwise leak this
        // sticky toast past dismissal; the presenter's stack keeps it alive until dismissed.
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

    /// Test hook: open a workspace the way the `⌘P` picker does — `⏎` into a new tab, `⇧⏎`
    /// replacing the current one — so a test drives the real staging of the recipe behind the
    /// canvas transition rather than calling `applyRecipe` directly.
    func openWorkspaceForTesting(_ ws: Workspace, replaceCurrentTab: Bool) {
        openWorkspace(ws, replaceCurrentTab: replaceCurrentTab)
    }

    /// Test hooks: the panel and surface scroll mode would target, so a test can assert what the
    /// header on screen reads rather than only what the mode's own flag says.
    var focusedPanelForTesting: PanelHostView? { activeController?.focusedScrollTarget?.panel }
    var focusedScrollTargetForTesting: (surface: TerminalSurface, panel: PanelHostView)? {
        activeController?.focusedScrollTarget
    }
    var focusedSurfaceForTesting: TerminalSurface? { activeController?.focusedScrollTarget?.surface }

    /// Any live surface in this window. For a caller that needs the *backend's* answer rather than a
    /// particular pane's: `disposition(of:)` reads the surface's own config and every surface shares
    /// the app's. Deliberately not the focused scroll target, which is nil whenever something other
    /// than a pane holds focus.
    var anyTerminalSurface: TerminalSurface? { activeController?.allSurfaces.first }

    /// Test hook: drive the real surface-failure toast so a test can click its actual buttons.
    func presentSurfaceFailureToastForTesting(retry: @escaping () -> Void, close: @escaping () -> Void) {
        presentSurfaceFailureToast(retry: retry, close: close)
    }

    /// Test hooks: drive the claude/waiting toast — the real `agentNotified` path (a background
    /// tab's agent asking for input), and the tab it targets — so a test can assert its ⌘N keycap
    /// against a live tab order instead of a hand-built toast.
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

    /// Test hook: open `count` extra tabs, so a test can drive tab-order changes under a live toast.
    func newTabForTesting() { handle(.newTab) }
    func closeTabForTesting(index: Int) {
        guard tabs.order.indices.contains(index) else { return }
        closeTab(tabs.order[index])
    }

    /// Test hook: the tab-bar chip click path (`onSelect` → `select`), which bypasses `handle(_:)`
    /// — so a test can prove the modal gates hold for the mouse, not just the keyboard.
    func selectTabForTesting(index: Int) {
        guard tabs.order.indices.contains(index) else { return }
        select(tabs.order[index])
    }

    /// Test hook: the tab-bar chip's double-click path (`onRename` → the card), which bypasses
    /// `handle(_:)` — so a test can prove the mouse route opens the card for the tab it clicked.
    func renameTabForTesting(index: Int) {
        guard tabs.order.indices.contains(index) else { return }
        openRenameTab(tabs.order[index])
    }

    /// Test hook: the window's float engine, for asserting the relays wired onto it.
    var floatsForTesting: ToolFloatController { floats }

    /// Test hooks: the live tab order and the titles the bar is rendering, so a reorder or a
    /// rename is asserted on what reaches the bar rather than on the model alone.
    var tabOrderForTesting: [TabID] { tabs.order }
    var tabTitlesForTesting: [String] { tabs.order.map { titles[$0] ?? "shell" } }

    /// Test hook: the active tab's id, so a test can name the tab a tab-scoped thing belongs to
    /// and prove it is not simply whichever one is up.
    var activeTabIDForTesting: TabID? { tabs.order.isEmpty ? nil : tabs.activeID }

    /// Test hook: whether the toast presenter has been built yet. The config observer must be able
    /// to re-point its insets WITHOUT constructing it — building it early would mount a toast stack
    /// in a window that has never shown one, which is the z-order the build-on-first-use protects.
    var hasBuiltToastsForTesting: Bool { builtToasts != nil }

    /// Test hook: the backdrop tint as it's actually painted. Its color comes from the theme and
    /// its alpha from `backdrop-alpha`, so it's the one probe covering both halves of that gate —
    /// and the tint view is private, with nothing in the tree to identify it by.
    var backdropTintColorForTesting: NSColor? {
        tint.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }

    /// Clear a tab's attention state and its toast. Called when the tab is shown or closed.
    /// Re-render is left to the caller, which is already mutating the tab bar.
    private func clearAttention(_ id: TabID) {
        attentionStates[id] = nil
        if let toast = attentionToasts.removeValue(forKey: id) { toasts.dismiss(toast) }
        AgentNotifier.shared.clear(windowID: windowID, tabID: id)  // also drop any OS banner for this tab
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
        // An attention toast is built once per notification, but its ⌘N keycap names the target tab's
        // CURRENT index — so re-resolve every live toast here, the one path every tab mutation
        // already runs through. Otherwise a toast for tab 3 keeps reading "⌘3" after tab 1 closes.
        attentionToasts.values.forEach { $0.refreshShortcuts() }
    }

    /// The chord that switches to `id` right now, for a waiting toast's keycap: the tab's live
    /// index resolved against the live keymap, so it tracks both rebinds and tab moves. Empty for a
    /// tab past ⌘9 (unbound) or one that's since closed — the keycap is then omitted entirely.
    /// Mirrors `TabBarView`'s tooltip lookup.
    private func selectTabShortcut(for id: TabID) -> String {
        guard let index = tabs.order.firstIndex(of: id).map({ $0 + 1 }), index <= 9 else { return "" }
        return CommandCatalog.spec(for: .selectTab(index)).shortcut
    }

    /// Mirror the active tab's overlay state + the window's command-palette state onto the
    /// dock's active tints. Called on tab switch, overlay toggles, and palette open/close.
    private func renderDock() {
        let overlay = activeController?.overlayState ?? OverlayState()
        // The shown float is window-level, so it comes from `floats`, not the active tab's state.
        dock.render(
            overlay: overlay, floatID: floats.activeID, paletteOpen: modal?.kind == .commandPalette,
            isLiveInBackground: floats.isLiveInBackground, isFloatBusy: floats.isBusy)
        // Keep the poll's change-guard in sync with what's actually shown, so a tab switch to a
        // differently-busy tab re-evaluates instead of comparing against a stale value.
        lastBusyDots = busyDots()
    }

    /// Wire the first controller once the dict is populated. Called from
    /// `mountAndStart()` before the first `mount(_:)` so the initial tab gets
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
        // Nothing may be built for this window after it goes: a card still loading would otherwise
        // arrive to a nil `activeController`, but only after constructing its overlay and kicking
        // off a git probe per workspace. `floats.shutdown()` below does the same for a float.
        pendingModal = nil
        // Closing the window with a confirm still up must resolve its owner's pending state —
        // e.g. a quit confirm's `.terminateLater` reply — or the app hangs mid-quit.
        cancelConfirm()
        // The keybind interceptor is shared app-wide. Closing this window while a Settings capture
        // is armed (a native red-button close is a mouse event the capture can't intercept) would
        // otherwise strand it in capture mode — swallowing every keystroke in every other window.
        keybindCapturer?.endCapture()
        // Same shared-handler hazard, same unconditional fix: a window closed while still key
        // never resigns key, and a mode left up keeps swallowing keys in every other window.
        // `windowDidResignKey` covers the ordinary path; this covers close.
        endModes()
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

    /// Scroll mode installs an app-global key handler, so it cannot outlive this window holding
    /// the keyboard: leaving it up would swallow keystrokes meant for whatever you switched to.
    func windowDidResignKey(_ notification: Notification) { endModes() }

    /// Quit terminates the process without closing windows, so `windowWillClose` never fires
    /// and every shell is orphaned instead of swept. The app delegate drives this on
    /// the way out. `tearDown()` is idempotent, so a window that closes normally afterwards is
    /// unaffected.
    func tearDownForQuit() { tearDown() }
}
