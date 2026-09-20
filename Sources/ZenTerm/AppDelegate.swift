import AppKit
import AppLog
import TabKit
import TerminalKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WindowController] = []
    private let worktreeRemovals = WorktreeRemovalTracker()
    private let keys = KeyInterceptor()
    private var navSocket: NavSocketServer?
    private var quitConfirmPending = false
    private var updateController: UpdateController?

    private lazy var configApplier = ConfigApplier(
        sinks: ConfigApplier.Sinks(
            setKeymap: { [weak self] map in self?.keys.setKeymap(map) },
            reportBackendShadow: { [weak self] in self?.reportBackendShadow() },
            applyMotion: { MotionConfig.apply($0) },
            announceDiagnostics: { [weak self] content, scope in
                guard let self else { return false }
                return WindowController.deliverConfigDiagnosticsNotice(
                    content, landingScope: scope, to: self.keyController(),
                    replacingAcross: self.windows)
            },
            retractDiagnostics: { [weak self] in
                self?.windows.forEach { $0.dismissConfigDiagnosticsToast() }
            },
            announceConflicts: { [weak self] conflicts in
                guard let self else { return false }
                return WindowController.deliverConflictNotices(
                    conflicts, to: self.keyController(), replacingAcross: self.windows)
            },
            retractConflicts: { [weak self] in
                self?.windows.forEach { $0.dismissConflictToasts() }
            },
            reapplyUpdateCardTheme: { [weak self] in self?.updateController?.reapplyTheme() },
            applyAutoCheckSetting: { [weak self] in self?.updateController?.applyAutoCheckSetting() },
            publishTheme: { ThemePublisher.publish() }))

    /// The menu goes up before the config load, which reads `NSApp.mainMenu` for the chords it protects.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.fileSink = .standard()

        worktreeRemovals.onChanged = { [weak self] change in
            for window in self?.windows ?? [] { window.worktreeRemovalsChanged(change) }
        }

        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])

        MainMenu.install()

        AppConfig.loadAtLaunch()
        MotionConfig.apply(GeneralConfig.current.reduceMotion)

        if GeneralConfig.current.debug { Log.isVerbose = true }
        Log.info("ZenTerm launched v\(AppVersion.current)", category: .app)

        newWindow(initialCWD: nil, centered: true)
        reportBackendShadow()
        configApplier.surfaceConfigNotices()
        ThemePublisher.publish()

        keys.onReservedChord = { [weak self] chord in self?.route(chord) }
        keys.passThroughGuard = { [weak self] chord, action in
            if TextEditingChords.owns(chord, firstResponder: NSApp.keyWindow?.firstResponder) {
                return true
            }
            let controller = self?.keyController()
            if PickerChordGuard.shouldPassThrough(
                action: action, repoPickerIsOpen: controller?.isRepoPickerOpen == true,
                sidebarHasFocus: controller?.isSidebarFocused == true)
            {
                return true
            }
            return NavGuard.shouldPassThrough(
                chord: chord, action: action,
                focusedPaneIsVim: controller?.focusedPaneIsVim == true,
                toolFloatIsOpen: controller?.isToolFloatOpen == true)
        }
        keys.onModifierChange = { [weak self] event in
            self?.windows.forEach { $0.modifiersDidChange(event) }
        }
        keys.setKeymap(GeneralConfig.current.keymap)
        keys.start()

        let socket = NavSocketServer { command in
            switch command {
            case .focus(let token, let dir): NavRegistry.shared.route(focus: token, dir)
            case .setVim(let token, let presence):
                NavRegistry.shared.setVim(token: token, presence != .off)
            }
        }
        socket.start()
        navSocket = socket

        AgentNotifier.shared.installDelegate()
        AgentNotifier.shared.onActivate = { [weak self] windowID, tabID in
            self?.activateTab(windowID: windowID, tabID: tabID)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows.forEach { $0.clearActiveTabNotification() } }
        }

        NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.configApplier.apply(ConfigChange.from(note)) }
        }

        if UpdateController.isSupported {
            let controller = UpdateController(keyController: { [weak self] in self?.keyController() })
            controller.start()
            updateController = controller
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func route(_ chord: KeyInterceptor.ReservedChord) {
        if case .newWindow = chord {
            if let key = keyController(), key.isModalOverlayOpen || key.isConfirmOpen { return }
            newWindow(
                initialCWD: ShellLaunch.newSessionCWD(focused: keyController()?.focusedCWD),
                centered: false)
            return
        }
        if case .reloadConfig = chord {
            AppConfig.reload(force: true)
            return
        }
        if case .checkForUpdates = chord {
            guard let updateController else {
                keyController()?.showToast(UpdateController.inertNotice)
                return
            }
            updateController.checkForUpdates()
            return
        }
        switch chord {
        case .increaseFontSize, .decreaseFontSize, .resetFontSize:
            if let key = keyController(), key.isModalOverlayOpen || key.isConfirmOpen { return }
            switch chord {
            case .increaseFontSize: applyFontSize { SessionFontSize.step(by: 1) }
            case .decreaseFontSize: applyFontSize { SessionFontSize.step(by: -1) }
            default: applyFontSize { SessionFontSize.reset() }
            }
        default: keyController()?.handle(chord)
        }
    }

    /// App-global because libghostty applies its own font-size binds to the focused surface alone.
    private func applyFontSize(_ move: () -> Void) {
        let before = SessionFontSize.points
        move()
        if SessionFontSize.points != before {
            for window in windows { window.applySessionFontSize() }
        }
        keyController()?.showFontSize(SessionFontSize.display)
    }

    private func activateTab(windowID: Int, tabID: TabID) {
        guard let wc = windows.first(where: { $0.windowID == windowID }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        wc.window.makeKeyAndOrderFront(nil)
        wc.selectTab(tabID)
    }

    static func window(
        holding path: URL, among windows: [WindowController], asking: WindowController?
    ) -> WindowController? {
        windows.first { $0 !== asking && $0.holdsWorkspace(at: path) }
    }

    private func otherWindow(holding path: URL, asking: WindowController?) -> WindowController? {
        Self.window(holding: path, among: windows, asking: asking)
    }

    private func keyController() -> WindowController? {
        guard let key = NSApp.keyWindow else { return windows.first }
        return windows.first { $0.window === key }
    }

    private func reportBackendShadow() {
        guard let surface = windows.lazy.compactMap({ $0.anyTerminalSurface }).first else { return }
        BackendShadow.report(assembled: GeneralConfig.current.keymap, probe: surface.disposition)
    }

    private func newWindow(initialCWD: URL?, centered: Bool) {
        let offset = CGFloat(windows.count) * 28
        let rect = NSRect(x: 0, y: 0, width: 900, height: 560).offsetBy(dx: offset, dy: -offset)
        let wc = WindowController(contentRect: rect, initialCWD: initialCWD)
        wc.keybindCapturer = keys
        wc.keyModeHost = keys
        wc.onAppGlobalCommand = { [weak self] chord in self?.route(chord) }
        wc.worktreeRemovals = worktreeRemovals
        wc.onClosedByRemovalAtPath = { [weak self, weak wc] path in
            self?.windows.reduce(ClosedByRemoval()) {
                $0.adding($1.closedByRemoval(atPath: path), isThisWindow: $1 === wc)
            } ?? ClosedByRemoval()
        }
        wc.openWorkspacesElsewhere = { [weak self, weak wc] in
            self?.windows.filter { $0 !== wc }.flatMap { $0.runningWorkspaces() } ?? []
        }
        wc.revealWorkspaceElsewhere = { [weak self, weak wc] window, id in
            guard
                let other = self?.windows.first(where: { $0 !== wc && $0.windowID == window }),
                other.holdsWorkspace(id)
            else { return false }
            NSApp.activate(ignoringOtherApps: true)
            if other.window.isMiniaturized { other.window.deminiaturize(nil) }
            other.window.makeKeyAndOrderFront(nil)
            other.activateWorkspace(id)
            return true
        }
        wc.isWorkspaceOpenInAnotherWindow = { [weak self, weak wc] path in
            self?.otherWindow(holding: path, asking: wc) != nil
        }
        wc.revealWorkspaceInAnotherWindow = { [weak self, weak wc] path in
            guard let other = self?.otherWindow(holding: path, asking: wc) else { return false }
            NSApp.activate(ignoringOtherApps: true)
            if other.window.isMiniaturized { other.window.deminiaturize(nil) }
            other.window.makeKeyAndOrderFront(nil)
            other.activateWorkspace(at: path)
            return true
        }
        if centered { wc.window.center() }
        wc.onClosed = { [weak self, weak wc] in
            guard let self, let wc else { return }
            self.windows.removeAll { $0 === wc }
        }
        windows.append(wc)
        wc.mountAndStart()
        wc.window.makeKeyAndOrderFront(nil)
    }

    /// No `windows.first` fallback: the Edit items stay enabled, so ⌘V would paste into a minimised shell.
    private func editVerbTarget() -> WindowController? {
        guard NSApp.keyWindow != nil else { return nil }
        return keyController()
    }
    @objc func copy(_ sender: Any?) {
        editVerbTarget()?.copy(sender)
    }
    @objc func paste(_ sender: Any?) {
        editVerbTarget()?.paste(sender)
    }
    @objc func selectAll(_ sender: Any?) {
        editVerbTarget()?.selectAll(sender)
    }

    /// Passes `AppVersion` because the About panel reads only `Info.plist`, which a `swift run` build lacks.
    @objc func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationVersion: AppVersion.current]
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            options[.version] = build
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc func showAcknowledgements(_ sender: Any?) {
        AcknowledgementsWindow.shared.show()
    }

    @objc func exportDiagnostics(_ sender: Any?) {
        keyController()?.exportDiagnostics()
    }

    @objc func reportAnIssue(_ sender: Any?) {
        keyController()?.openReportIssue()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        navSocket?.stop()
    }

    /// `windowWillClose` does not fire on termination, so quit has to tear each window down itself.
    private func tearDownAllWindows(then completion: @escaping () -> Void) {
        for wc in windows { wc.tearDownForQuit() }
        drainSessionSweeps(then: completion)
    }

    private func drainSessionSweeps(then completion: @escaping () -> Void) {
        ShellSessionReaper.shared.drainForQuit(
            timeout: ShellSessionReaper.quitSweepBudget, completion: completion)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let key = keyController() else {
            worktreeRemovals.whenIdle {
                self.drainSessionSweeps { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }
        if quitConfirmPending { return .terminateCancel }
        quitConfirmPending = true
        let tabCount = windows.reduce(0) { $0 + $1.tabCount }
        key.presentQuitConfirm(
            tabCount: tabCount, windowCount: windows.count,
            onQuit: { [weak self] in
                guard let self else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                self.quitConfirmPending = false
                self.tearDownAllWindows {
                    self.worktreeRemovals.whenIdle { NSApp.reply(toApplicationShouldTerminate: true) }
                }
            },
            onCancel: { [weak self] in
                self?.quitConfirmPending = false
                NSApp.reply(toApplicationShouldTerminate: false)
            })
        return .terminateLater
    }

    #if DEBUG
        func addWindowForTesting() { newWindow(initialCWD: nil, centered: false) }

        func quitTeardownForTesting(then completion: @escaping () -> Void) {
            tearDownAllWindows(then: completion)
        }
    #endif
}
