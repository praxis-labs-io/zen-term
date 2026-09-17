import AppKit
import AppLog
import GhosttyKit

public final class GhosttySurface: NSObject, TerminalSurface {
    private let hostView = GhosttyHostView()
    var surfacePtr: ghostty_surface_t?
    private var lastTitle = ""
    private var lastCwd: URL?

    private var wantsSecureInput = false
    private var secureInputID: ObjectIdentifier { ObjectIdentifier(self) }

    private var lastTheme: TerminalTheme?
    private var lastBehavior: TerminalBehavior = .default

    public private(set) var backgroundOverride: TerminalColor?

    // Every per-surface config push carries it, or libghostty resets an unadjusted surface to the config's size.
    private var lastFontSize: CGFloat?

    // A scheme push triggers a config reload that can re-derive the scheme, so a repeat must be silent.
    private var lastReportedScheme: ghostty_color_scheme_e?

    private(set) var lastFocused = true

    private var paneFocused = true

    // ghostty runs the shader draw timer at 120fps while a surface believes it is focused.
    private var isAppActive = true

    private var appActiveObservers: [NSObjectProtocol] = []

    private var shaderSettleWorkItem: DispatchWorkItem?

    private var hasPerSurfaceShaderConfig = false

    // Clears the bundled shaders' 0.35s and 0.15s cursor-tail decay with margin.
    private static let shaderSettleDuration: TimeInterval = 0.5

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { hostView }
    public var title: String { lastTitle }
    public var isFocused: Bool { hostView.window?.firstResponder === hostView }
    public var currentDirectory: URL? { lastCwd }

    // Reads OSC 133 prompt marks: a shell without integration reads busy, a background job does not.
    public var isBusy: Bool {
        guard let surfacePtr else { return false }
        return ghostty_surface_needs_confirm_quit(surfacePtr)
    }

    public override init() {
        super.init()
        hostView.owner = self
        observeAppActive()
    }

    // Syncs focus and occlusion at birth: libghostty defaults a new surface to focused and visible.
    public func start(_ config: TerminalSurfaceConfig) {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(
            hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = config.fontSize.map { Float($0) } ?? 0

        let command: String? = config.command.map { cmd in
            ([cmd] + config.args).map(Self.shellWordQuote).joined(separator: " ")
        }

        surfacePtr = Self.withConfigStrings(
            &cfg,
            workingDirectory: config.workingDirectory?.path,
            command: command,
            environment: config.environment
        ) { ghostty_surface_new(GhosttyApp.shared(theme: config.theme, behavior: config.behavior).app, &$0) }

        hostView.surfacePtr = surfacePtr

        guard surfacePtr != nil else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.surfaceDidFailToStart(self)
            }
            return
        }

        Self.recordShellSessions()

        lastTheme = config.theme
        lastBehavior = config.behavior ?? .default
        lastFontSize = config.fontSize ?? config.theme?.fontSize
        hostView.scrollMultiplier = (config.behavior ?? .default).scrollMultiplier

        paneFocused = hostView.window?.firstResponder === hostView
        isAppActive = NSApp.isActive
        let bornFocused = paneFocused && isAppActive
        ghostty_surface_set_focus(surfacePtr, bornFocused)
        lastFocused = bornFocused
        hostView.syncOcclusion()
        if !bornFocused {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.lastFocused else { return }
                self.startShaderSettle()
            }
        }

        applyLayerBacking(theme: config.theme, behavior: config.behavior ?? .default)
        syncColorScheme()

        hostView.syncDisplayID()
        hostView.syncSizeAndScale()
        GhosttyApp.shared.tick()
    }

    // Double quotes: libghostty's shell detector strips only those, and a single quote breaks integration.
    static func shellWordQuote(_ word: String) -> String {
        var escaped = ""
        for character in word {
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\"" + escaped + "\""
    }

    private static func withConfigStrings<T>(
        _ config: inout ghostty_surface_config_s,
        workingDirectory: String?,
        command: String?,
        environment: [String: String],
        _ body: (inout ghostty_surface_config_s) -> T
    ) -> T {
        withOptionalCString(workingDirectory) { cwd in
            config.working_directory = cwd
            return withOptionalCString(command) { cmd in
                config.command = cmd
                let keys = Array(environment.keys)
                let values = keys.map { environment[$0]! }
                return keys.withCStrings { keyPtrs in
                    values.withCStrings { valuePtrs in
                        var envVars = (0..<keys.count).map {
                            ghostty_env_var_s(key: keyPtrs[$0], value: valuePtrs[$0])
                        }
                        return envVars.withUnsafeMutableBufferPointer { buf in
                            config.env_vars = buf.baseAddress
                            config.env_var_count = keys.count
                            return body(&config)
                        }
                    }
                }
            }
        }
    }

    // Samples because libghostty forks the shell after `ghostty_surface_new` returns.
    private static func recordShellSessions() {
        ShellSessionLedger.shared.sample(for: 0.5, every: 0.025)
    }

    // Keeps `backgroundOverride`: libghostty leaves a program's OSC 11 color in place across a config change.
    public func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {
        lastTheme = theme
        lastBehavior = behavior
        GhosttyApp.shared.updateConfig(theme: theme, behavior: behavior)
        if hasPerSurfaceShaderConfig {
            if behavior.cursorShader == nil {
                cancelShaderSettle()
                hasPerSurfaceShaderConfig = false
            } else if shaderSettleWorkItem != nil {
                applyShaderConfig(behavior, animation: .always)
            } else {
                applyShaderConfig(stoodDownBehavior, animation: .whileFocused)
            }
        }
        applyLayerBacking(theme: theme, behavior: behavior)
        hostView.scrollMultiplier = behavior.scrollMultiplier
        syncColorScheme()
        if let surfacePtr { ghostty_surface_refresh(surfacePtr) }
        adoptGridBaseline()
    }

    // From the background, not `effectiveAppearance`, which reads light for a dark theme on a light system.
    private func syncColorScheme() {
        guard let surfacePtr, let background = backgroundOverride ?? lastTheme?.background else {
            return
        }
        let scheme = background.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        guard scheme != lastReportedScheme else { return }
        lastReportedScheme = scheme
        ghostty_surface_set_color_scheme(surfacePtr, scheme)
    }

    // libghostty asks for this after `set_color_scheme`; only the config push carries the scheme into `Termio`.
    private func reapplySurfaceConfig() {
        guard let surfacePtr else { return }
        let pushed: Bool
        if hasPerSurfaceShaderConfig {
            pushed =
                shaderSettleWorkItem != nil
                ? applyShaderConfig(lastBehavior, animation: .always)
                : applyShaderConfig(stoodDownBehavior, animation: .whileFocused)
        } else {
            pushed = GhosttyApp.shared.updateSurfaceConfig(
                surfacePtr, theme: lastTheme, behavior: lastBehavior,
                shaderAnimation: .whileFocused, fontSize: lastFontSize)
        }
        if !pushed { lastReportedScheme = nil }
    }

    // A binding action marks the surface `font_size_adjusted`, so later theme sizes no longer land on it.
    public func setFontSize(_ points: CGFloat) {
        lastFontSize = points
        performBindingAction("set_font_size:\(points)")
        adoptGridBaseline()
    }

    // `logsFailure` is off for actions whose false means "nothing to do", not a rejection.
    private func performBindingAction(_ action: String, logsFailure: Bool = true) {
        guard let surfacePtr else { return }
        let performed = action.withCString {
            ghostty_surface_binding_action(surfacePtr, $0, UInt(action.utf8.count))
        }
        if !performed && logsFailure {
            Log.error("GhosttySurface: libghostty rejected \(action)", category: .surface)
        }
    }

    // No escaping needed: libghostty splits the action on the first colon only.
    public func search(_ needle: String) {
        performBindingAction("search:\(needle)", logsFailure: false)
    }

    public func stepSearch(_ step: TerminalSearchStep) {
        let direction = step == .next ? "next" : "previous"
        performBindingAction("navigate_search:\(direction)", logsFailure: false)
    }

    public func endSearch() {
        performBindingAction("end_search", logsFailure: false)
    }

    // Opaque when solid so the compositor never blends against the vibrancy backdrop; translucent needs both off.
    private func applyLayerBacking(theme: TerminalTheme?, behavior: TerminalBehavior) {
        guard let layer = hostView.layer else { return }
        let isSolid = behavior.isBackgroundSolid
        let fill = backgroundOverride ?? theme?.background
        layer.isOpaque = isSolid
        layer.backgroundColor = isSolid ? (fill?.nsColor ?? .black).cgColor : nil
        layer.contentsGravity = isSolid ? .topLeft : .resize
    }

    public func focus() { hostView.window?.makeFirstResponder(hostView) }

    public func setFocused(_ focused: Bool) {
        handleFocusChange(focused)
    }

    public func modifiersDidChange(_ event: NSEvent) {
        hostView.flagsChanged(with: event)
    }

    private func handleFocusChange(_ focused: Bool) {
        paneFocused = focused
        syncFocus()
    }

    private func handleAppActiveChange(_ active: Bool) {
        isAppActive = active
        syncFocus()
    }

    // Forgets held modifiers on effective blur, since a pane keeps first responder across ⌘-Tab.
    private func syncFocus() {
        let focused = paneFocused && isAppActive
        if let surfacePtr { ghostty_surface_set_focus(surfacePtr, focused) }
        guard focused != lastFocused else { return }
        lastFocused = focused
        if !focused { hostView.forgetHeldModifiers() }
        if focused { restoreShader() } else { startShaderSettle() }
    }

    private func observeAppActive() {
        let center = NotificationCenter.default
        appActiveObservers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.handleAppActiveChange(true) },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.handleAppActiveChange(false) },
        ]
    }

    private func removeAppActiveObservers() {
        appActiveObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appActiveObservers = []
    }

    // Stands down to a passthrough, not no shader: ghostty stops updating cursor uniforms with none loaded.
    private func startShaderSettle() {
        guard lastBehavior.cursorShader != nil, surfacePtr != nil else { return }
        cancelShaderSettle()
        applyShaderConfig(lastBehavior, animation: .always)
        hasPerSurfaceShaderConfig = true

        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyShaderConfig(self.stoodDownBehavior, animation: .whileFocused)
            self.shaderSettleWorkItem = nil
        }
        shaderSettleWorkItem = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shaderSettleDuration, execute: settle)
    }

    private func restoreShader() {
        cancelShaderSettle()
        guard hasPerSurfaceShaderConfig else { return }
        applyShaderConfig(lastBehavior, animation: .whileFocused)
        hasPerSurfaceShaderConfig = false
    }

    private var stoodDownBehavior: TerminalBehavior {
        var stoodDown = lastBehavior
        stoodDown.cursorShader = TerminalKitResources.passthroughShaderPath
        return stoodDown
    }

    @discardableResult
    private func applyShaderConfig(
        _ behavior: TerminalBehavior, animation: GhosttyConfigWriter.ShaderAnimation
    ) -> Bool {
        guard let surfacePtr else { return false }
        return GhosttyApp.shared.updateSurfaceConfig(
            surfacePtr, theme: lastTheme, behavior: behavior, shaderAnimation: animation,
            fontSize: lastFontSize)
    }

    private func cancelShaderSettle() {
        shaderSettleWorkItem?.cancel()
        shaderSettleWorkItem = nil
    }

    // Records sessions before the free, which closes the pty; the reap after it catches what SIGHUP missed.
    public func terminate() {
        SecureInput.shared.removeScoped(secureInputID)
        cancelShaderSettle()
        removeAppActiveObservers()
        guard let surfacePtr else { return }
        ShellSessionLedger.shared.record(ShellSession.leaderChildren())
        ghostty_surface_free(surfacePtr)
        self.surfacePtr = nil
        hostView.surfacePtr = nil
        ShellSessionReaper.shared.reapOrphans()
    }

    // Backstop for a release that skips `terminate()`; libghostty holds an unretained pointer to self.
    deinit {
        SecureInput.shared.removeScoped(secureInputID)
        removeAppActiveObservers()
        if let surfacePtr {
            ShellSessionLedger.shared.record(ShellSession.leaderChildren())
            ghostty_surface_free(surfacePtr)
            hostView.surfacePtr = nil
            ShellSessionReaper.shared.reapOrphans()
        }
    }

    func focusDidChange(_ focused: Bool) {
        if wantsSecureInput { SecureInput.shared.setScoped(secureInputID, focused: focused) }
        handleFocusChange(focused)
    }

    // `PERFORMABLE` is a set lookup that never checks whether the action would act, hence `.mayClaim`.
    public func disposition(of key: TerminalKey) -> ChordDisposition {
        guard let surfacePtr else { return .ignores }
        var flags = ghostty_binding_flags_e(0)
        var event = Self.ghosttyKey(key)
        let matched = { (text: UnsafePointer<CChar>?) -> Bool in
            event.text = text
            return ghostty_surface_key_is_binding(surfacePtr, event, &flags)
        }
        guard key.text.map({ $0.withCString(matched) }) ?? matched(nil) else { return .ignores }
        if flags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue == 0 { return .claimsButPasses }
        if flags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue != 0 { return .mayClaim }
        return .claims
    }

    // Leaves `consumed_mods` unset: `Binding.Set.getEvent` never reads it.
    private static func ghosttyKey(_ key: TerminalKey) -> ghostty_input_key_s {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = UInt32(key.keyCode)
        event.mods = NSEvent.ghosttyMods(key.modifiers)
        event.unshifted_codepoint = key.unshiftedCodepoint
        event.composing = false
        return event
    }

    public func paste(_ text: String) {
        guard let surfacePtr else { return }
        let byteCount = UInt(text.utf8.count)
        text.withCString { ghostty_surface_text(surfacePtr, $0, byteCount) }
    }

    public func copySelection() -> String? {
        guard let surfacePtr, ghostty_surface_has_selection(surfacePtr) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard let ptr = text.text else { return nil }
        return String(cString: ptr)
    }

    // libghostty reports the top-left as the text baseline in points, and -1 once scrolled out of view.
    public var selectionOrigin: TerminalViewportCell? {
        guard let surfacePtr, ghostty_surface_has_selection(surfacePtr) else { return nil }
        guard let metrics = cellMetrics, metrics.cellWidth > 0, metrics.cellHeight > 0 else {
            return nil
        }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard text.tl_px_x >= 0, text.tl_px_y >= 0 else { return nil }
        let x = (CGFloat(text.tl_px_x) - metrics.gridInset) / metrics.cellWidth
        let y = (CGFloat(text.tl_px_y) - metrics.gridInset) / metrics.cellHeight
        return TerminalViewportCell(
            row: min(max(Int(y.rounded(.down)), 0), max(metrics.rows - 1, 0)),
            column: min(max(Int(x.rounded(.down)), 0), max(metrics.columns - 1, 0)))
    }

    public var cellMetrics: TerminalCellMetrics? {
        guard let surfacePtr else { return nil }
        let size = ghostty_surface_size(surfacePtr)
        guard size.cell_height_px > 0, size.cell_width_px > 0 else { return nil }
        let scale = hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return TerminalCellMetrics(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellWidth: CGFloat(size.cell_width_px) / scale,
            cellHeight: CGFloat(size.cell_height_px) / scale,
            gridInset: GhosttyConfigWriter.gridInset)
    }

    // One row per call: libghostty unwraps soft wraps, so a multi-row read loses row alignment.
    public func text(viewportRow row: Int) -> String? {
        guard let metrics = cellMetrics, row >= 0, row < metrics.rows else { return nil }
        return text(
            in: TerminalViewportRange(
                startRow: row, startColumn: 0, endRow: row,
                endColumn: max(metrics.columns - 1, 0)),
            metrics: metrics)
    }

    public func text(in range: TerminalViewportRange) -> String? {
        guard let metrics = cellMetrics else { return nil }
        return text(in: range, metrics: metrics)
    }

    private func text(in range: TerminalViewportRange, metrics: TerminalCellMetrics) -> String? {
        guard let surfacePtr else { return nil }
        let lastRow = max(metrics.rows - 1, 0)
        guard range.startRow >= 0, range.startRow <= lastRow, range.endRow <= lastRow else {
            return nil
        }
        var selection = ghostty_selection_s()
        selection.top_left = Self.viewportPoint(x: UInt32(max(range.startColumn, 0)), y: range.startRow)
        selection.bottom_right = Self.viewportPoint(x: UInt32(max(range.endColumn, 0)), y: range.endRow)
        selection.rectangle = false
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surfacePtr, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard let ptr = text.text else { return nil }
        return String(cString: ptr)
    }

    // libghostty sends -1 for none; the selected index is zero-based despite its header comment.
    private static func searchCount(_ value: ssize_t) -> Int? {
        value < 0 ? nil : Int(value)
    }

    private static func viewportPoint(x: UInt32, y: Int) -> ghostty_point_s {
        var point = ghostty_point_s()
        point.tag = GHOSTTY_POINT_VIEWPORT
        point.coord = GHOSTTY_POINT_COORD_EXACT
        point.x = x
        point.y = UInt32(max(y, 0))
        return point
    }

    public func scroll(_ command: TerminalScroll) {
        switch command {
        case .lines(let n): performBindingAction("scroll_page_lines:\(n)")
        case .pageFraction(let f): performBindingAction("scroll_page_fractional:\(f)")
        case .top: performBindingAction("scroll_to_top")
        case .bottom: performBindingAction("scroll_to_bottom")
        case .selection: performBindingAction("scroll_to_selection", logsFailure: false)
        case .prompt(let n): performBindingAction("jump_to_prompt:\(n)", logsFailure: false)
        }
    }

    // libghostty reports false on the alternate screen, which is not a rejection.
    public func clearScreen() {
        performBindingAction("clear_screen", logsFailure: false)
    }

    public func selectAll() {
        performBindingAction("select_all")
    }

    public func writeScreenToFile(_ disposition: ScreenFileDisposition) {
        switch disposition {
        case .paste: performBindingAction("write_screen_file:paste")
        case .copy: performBindingAction("write_screen_file:copy")
        case .open: performBindingAction("write_screen_file:open")
        }
    }

    public func setSizeSyncSuspended(_ suspended: Bool) {
        hostView.setSizeSyncSuspended(suspended)
    }

    func reportFocusWanted() { delegate?.surfaceWantsFocus(self) }

    private var lastGrid: (columns: Int, rows: Int)?

    // libghostty sets the grid synchronously but rewraps text later. The first sizing is not a reflow.
    func reportGridIfChanged() {
        guard let metrics = cellMetrics else { return }
        let grid = (columns: metrics.columns, rows: metrics.rows)
        let previous = lastGrid
        lastGrid = grid
        guard let previous, previous != grid else { return }
        delegate?.surfaceGridDidReflow(self)
    }

    // A font step reshapes the grid outside a size push; a stale baseline would announce a false reflow.
    private func adoptGridBaseline() {
        guard let metrics = cellMetrics else { return }
        lastGrid = (columns: metrics.columns, rows: metrics.rows)
    }

    // Child exit is reported a turn later: freeing the surface inside `ghostty_app_tick` is a use-after-free.
    func handle(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let cStr = action.action.set_title.title else { return false }
            lastTitle = String(cString: cStr)
            delegate?.surface(self, titleDidChange: lastTitle)
            return true
        case GHOSTTY_ACTION_PWD:
            guard let cStr = action.action.pwd.pwd else { return false }
            let path = String(cString: cStr)
            let url = OSC7.fileURL(from: path) ?? URL(fileURLWithPath: path)
            lastCwd = url
            delegate?.surface(self, cwdDidChange: url)
            return true
        case GHOSTTY_ACTION_RING_BELL:
            delegate?.surfaceDidRingBell(self)
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let notification = action.action.desktop_notification
            let title = notification.title.map { String(cString: $0) } ?? ""
            let body = notification.body.map { String(cString: $0) } ?? ""
            delegate?.surface(
                self, didPostNotification: TerminalNotification(title: title, body: body))
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            delegate?.surface(self, progressDidChange: Self.progress(action.action.progress_report))
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            delegate?.surface(
                self, commandDidFinish: Self.commandResult(action.action.command_finished))
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let code = Int32(action.action.child_exited.exit_code)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.surfaceDidExit(self, code: code)
            }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            hostView.applyMouseShape(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            hostView.setCursorVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            openURL(action.action.open_url)
            return true
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            delegate?.surface(self, hoveredLinkDidChange: Self.hoveredLink(action.action.mouse_over_link))
            return true
        case GHOSTTY_ACTION_SECURE_INPUT:
            setSecureInput(for: action.action.secure_input)
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            applyColorChange(action.action.color_change)
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reapplySurfaceConfig()
            return true
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY {
                Log.info("GhosttySurface: renderer recovered", category: .surface)
            } else {
                Log.error(
                    "GhosttySurface: renderer unhealthy, pane may render black",
                    category: .surface)
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            let bar = action.action.scrollbar
            delegate?.surface(
                self,
                scrollPositionDidChange: TerminalScrollPosition(
                    total: Int(bar.total), offset: Int(bar.offset), viewport: Int(bar.len)))
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            delegate?.surface(self, wantsSearchWithNeedle: needle)
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            delegate?.surface(self, searchTotalDidChange: Self.searchCount(action.action.search_total.total))
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            delegate?.surface(
                self, searchSelectionDidChange: Self.searchCount(action.action.search_selected.selected))
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            delegate?.surfaceDidEndSearch(self)
            return true
        default:
            return false
        }
    }

    static func commandResult(_ finished: ghostty_action_command_finished_s) -> TerminalCommandResult {
        TerminalCommandResult(
            exitCode: finished.exit_code < 0 ? nil : Int(finished.exit_code),
            duration: TimeInterval(finished.duration) / 1_000_000_000)
    }

    // Deferred scheme sync: this runs inside libghostty's mailbox drain, and an inline push would reorder colors.
    private func applyColorChange(_ change: ghostty_action_color_change_s) {
        guard case .background(let color) = Self.effect(of: change) else { return }
        backgroundOverride = color
        applyLayerBacking(theme: lastTheme, behavior: lastBehavior)
        delegate?.surface(self, backgroundDidChange: color)
        DispatchQueue.main.async { [weak self] in self?.syncColorScheme() }
    }

    // A reset is carried as a color: libghostty's `DynamicRGB.reset` pins `override = default`, never null.
    static func effect(of change: ghostty_action_color_change_s) -> ColorChangeEffect {
        guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return .ignored }
        return .background(TerminalColor(red: change.r, green: change.g, blue: change.b))
    }

    enum ColorChangeEffect: Equatable {
        case background(TerminalColor)
        case ignored
    }

    static func hoveredLink(_ link: ghostty_action_mouse_over_link_s) -> String? {
        guard let ptr = link.url, link.len > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(link.len)), as: UTF8.self)
    }

    // A scheme-less string is a path: `NSWorkspace.open` silently no-ops on it as a URL (ghostty-org/ghostty#8763).
    private func openURL(_ openURL: ghostty_action_open_url_s) {
        guard let ptr = openURL.url else { return }
        let string = String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(openURL.len)), as: UTF8.self)
        let url: URL
        if let candidate = URL(string: string), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: NSString(string: string).standardizingPath)
        }
        NSWorkspace.shared.open(url)
    }

    private func setSecureInput(for action: ghostty_action_secure_input_e) {
        switch action {
        case GHOSTTY_SECURE_INPUT_ON: wantsSecureInput = true
        case GHOSTTY_SECURE_INPUT_OFF: wantsSecureInput = false
        default: wantsSecureInput.toggle()
        }
        if wantsSecureInput {
            SecureInput.shared.setScoped(secureInputID, focused: isFocused)
        } else {
            SecureInput.shared.removeScoped(secureInputID)
        }
    }

    private static func progress(_ report: ghostty_action_progress_report_s) -> TerminalProgress? {
        let fraction = report.progress >= 0 ? Double(report.progress) / 100.0 : nil
        switch report.state {
        case GHOSTTY_PROGRESS_STATE_REMOVE: return nil
        case GHOSTTY_PROGRESS_STATE_SET: return TerminalProgress(state: .running, fraction: fraction)
        case GHOSTTY_PROGRESS_STATE_ERROR: return TerminalProgress(state: .error, fraction: fraction)
        case GHOSTTY_PROGRESS_STATE_PAUSE: return TerminalProgress(state: .paused, fraction: fraction)
        default: return TerminalProgress(state: .indeterminate)
        }
    }
}

private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

private extension Array where Element == String {
    func withCStrings<T>(_ body: ([UnsafePointer<CChar>?]) -> T) -> T {
        func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>?], _ body: ([UnsafePointer<CChar>?]) -> T) -> T {
            if index == count { return body(acc) }
            return self[index].withCString { recurse(index + 1, acc + [$0], body) }
        }
        return recurse(0, [], body)
    }
}
