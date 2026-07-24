import AppKit
import GhosttyKit

/// libghostty-backed terminal surface — the sole backend (ZEN-45, ZEN-66).
///
/// It sits behind the `TerminalSurface` seam so the chrome never touches libghostty
/// directly. libghostty renders into a Metal layer it attaches to a host view we own,
/// and the host must
/// forward every input (key / mouse / focus / size / scale) and pump the shared app's
/// event loop. IME/dead-key composition is not wired yet (no `NSTextInputClient`);
/// tracked in ZEN-67.
public final class GhosttySurface: NSObject, TerminalSurface {
    private let hostView = GhosttyHostView()
    var surfacePtr: ghostty_surface_t?
    private var lastTitle = ""
    private var lastCwd: URL?

    /// Whether libghostty has this surface in a password context
    /// (`GHOSTTY_ACTION_SECURE_INPUT`). Secure keyboard entry is process-global, so we don't
    /// drive it directly — we hand desire + focus to `SecureInput.shared`, which scopes the
    /// global lock to focus and app-active state.
    private var wantsSecureInput = false
    private var secureInputID: ObjectIdentifier { ObjectIdentifier(self) }

    /// The theme and behavior last applied, retained so the settle-burst can regenerate this
    /// surface's config without the chrome handing them over again (ZEN-237).
    private var lastTheme: TerminalTheme?
    private var lastBehavior: TerminalBehavior = .default

    /// Focus as libghostty last heard it, which is what tells a real blur from a repeat: the
    /// chrome re-sends every surface's focus state on any focus change, and a settle-burst per
    /// repeat would re-shape an idle pane's viewport for nothing.
    ///
    /// Seeded `true` to match libghostty, whose renderer thread defaults `flags.focused = true`
    /// and leaves it "up to the apprt to set the correct value". Seeding `false` would swallow
    /// the first real blur of a surface that was never focused — the new-workspace drawers.
    private var lastFocused = true

    /// The pending shader strip that follows a settle-burst. Cancelled by a refocus inside the
    /// window, and by `terminate`.
    private var shaderSettleWorkItem: DispatchWorkItem?

    /// Whether this surface is running a per-surface config that differs from the app-global one
    /// (mid-burst, or shader-stripped afterwards). Refocusing puts the app-global shape back.
    private var hasPerSurfaceShaderConfig = false

    /// How long a blurred surface keeps animating so its cursor tail can decay to nothing. The
    /// bundled shaders decay in 0.35s (`cursor_warp`) and 0.15s (`cursor_tail`), so this clears
    /// the slower one with margin while keeping the 120fps window on an unwatched pane short.
    private static let shaderSettleDuration: TimeInterval = 0.5

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { hostView }
    public var title: String { lastTitle }
    public var isFocused: Bool { hostView.window?.firstResponder === hostView }
    public var currentDirectory: URL? { lastCwd }

    /// Whether the shell has a running foreground command, via ghostty's
    /// needs-confirm-quit signal — which, with our default `confirm-close-surface`,
    /// reports "cursor is not at a prompt" from shell integration (OSC 133 marks).
    /// For an integration-capable shell (zsh, the macOS default) an idle prompt reads
    /// as not busy and a running command as busy. A shell ghostty can't integrate
    /// (Apple's /bin/bash) has no prompt marks, so this conservatively reads busy —
    /// erring toward an extra close confirmation, never toward losing live work.
    /// True process-group parity is tracked as a follow-up (ZEN-69).
    public var isBusy: Bool {
        guard let surfacePtr else { return false }
        return ghostty_surface_needs_confirm_quit(surfacePtr)
    }

    public override init() {
        super.init()
        hostView.owner = self
    }

    public func start(_ config: TerminalSurfaceConfig) {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
        // Surface-level userdata: how the C callbacks recover this object (see GhosttyApp).
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(
            hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = config.fontSize.map { Float($0) } ?? 0

        // libghostty's `command` is a single string, not argv: it runs the string via a
        // login shell (`bash -c "<string>"`) AND tokenizes the same string with Zig's
        // ArgIteratorGeneral to detect the shell for integration. That tokenizer strips
        // DOUBLE quotes only — single quotes would survive into arg0 (`'zsh'` != `zsh`)
        // and silently disable shell integration (cwd tracking, prompt marks → isBusy).
        // So each word is double-quoted; both the exec and the detector agree. The chrome
        // spawns tool floats as `-c "cmd; exec zsh -l -i"`, so this is load-bearing.
        // `command == nil` lets libghostty launch the user's login shell itself.
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

        // A nil surface means `ghostty_surface_new` failed — the object stays alive but
        // inert. Signal the chrome (which shows a toast + retry/close) and stop before the
        // focus/layer/tick work below, which would otherwise run against a nil pointer.
        guard surfacePtr != nil else {
            // Deliver on the next main-loop turn, not synchronously inside `start()`: callers
            // wire the surface into their own state around this call (a drawer ivar assigned
            // after `start`, the pane registry), and the chrome dispatches this callback by
            // surface identity. A synchronous callback would run before that wiring exists —
            // silently dropped — and before the caller finishes mounting a surface it would
            // then have to unwind. Deferring lets construction complete first.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.surfaceDidFailToStart(self)
            }
            return
        }

        lastTheme = config.theme
        lastBehavior = config.behavior ?? .default
        hostView.scrollMultiplier = (config.behavior ?? .default).scrollMultiplier

        // A fresh libghostty surface defaults to focused=true, and only `resignFirstResponder`
        // ever flips it false — so a surface that never becomes first responder (a hidden drawer,
        // a background pane, a dismissed tool float) would keep an active/blinking cursor. Sync focus to the
        // real first-responder state now that the surface exists. This also covers a view that
        // became first responder before `surfacePtr` was set (the `becomeFirstResponder` true
        // was skipped under its `if let surfacePtr` guard).
        ghostty_surface_set_focus(surfacePtr, hostView.window?.firstResponder === hostView)

        // libghostty just made hostView layer-hosting (its Metal layer is now
        // hostView.layer). The host window is transparent for the vibrancy backdrop, so
        // by default the compositor blends this layer against that backdrop every frame —
        // which tears under heavy TUI redraws and flashes the (light) backdrop through any
        // redraw gap. Mark the layer opaque over the terminal background so it composites
        // as a solid surface and gaps show the terminal bg, not the window behind it.
        //
        // Exception: with a custom shader active, ghostty's shader pass writes real alpha into
        // the drawable; an opaque layer tells Core Animation to ignore that alpha, which flashes
        // the backdrop through on the alt-screen full redraw. So drop opacity when a shader is
        // on, but keep the opaque backgroundColor so an ordinary redraw gap still shows the
        // terminal bg rather than the window behind it.
        if let layer = hostView.layer {
            layer.isOpaque = (config.behavior ?? .default).cursorShader == nil
            layer.backgroundColor = (config.theme?.background.nsColor ?? .black).cgColor
        }

        // The host view may already be mounted, in which case its own `viewDidMoveToWindow`
        // ran before `surfacePtr` existed and couldn't push the display id.
        hostView.syncDisplayID()
        hostView.syncSizeAndScale()
        GhosttyApp.shared.tick()
    }

    /// Quote one word in DOUBLE quotes, backslash-escaping the four characters special
    /// inside a POSIX double-quoted string (`\`, `"`, `$`, `` ` ``). Double quotes, not
    /// single, because libghostty's shell-integration detector (Zig ArgIteratorGeneral)
    /// strips only double quotes — single-quoted words would defeat shell detection.
    /// `bash -c` honors the same double-quote rules, so the exec re-splits correctly too.
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

    /// Fills the config's C-string pointers (working dir, command, env) with buffers that
    /// live only for `body`, matching libghostty's requirement that they stay valid across
    /// `ghostty_surface_new`.
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

    /// Re-apply appearance/behavior in place. libghostty config is app-global, so this
    /// re-themes every surface via `GhosttyApp.updateConfig` (deduped there); the pieces
    /// scoped to this surface (opaque-layer bg, scroll multiplier, redraw) are applied here.
    public func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {
        lastTheme = theme
        lastBehavior = behavior
        GhosttyApp.shared.updateConfig(theme: theme, behavior: behavior)
        if let layer = hostView.layer {
            // Reset the opaque-layer background (the same trick start(_:) uses) so redraw gaps
            // show the new terminal bg, not the old one; and re-derive opacity, since toggling a
            // cursor shader on/off flips whether the layer must pass the drawable's real alpha.
            layer.isOpaque = behavior.cursorShader == nil
            layer.backgroundColor = theme.background.nsColor.cgColor
        }
        hostView.scrollMultiplier = behavior.scrollMultiplier
        if let surfacePtr { ghostty_surface_refresh(surfacePtr) }
    }

    public func focus() { hostView.window?.makeFirstResponder(hostView) }

    public func setFocused(_ focused: Bool) {
        guard focused != lastFocused else { return }
        lastFocused = focused
        if let surfacePtr { ghostty_surface_set_focus(surfacePtr, focused) }
        if focused { restoreShader() } else { startShaderSettle() }
    }

    /// Let a blurred surface's cursor tail finish, then stand the real shader down (ZEN-237).
    ///
    /// Two steps, because a blurred surface has two ways to show a tracer. The tail already in
    /// flight at blur needs frames to decay, which the burst into `always` gives it. But the
    /// bigger case is a smear painted *after* the blur: `drawFrame` gates on visible, not
    /// focused, so a cursor move on an unfocused pane (a shell reaching its first prompt, an
    /// agent writing output) still draws one damage-driven frame, and with the focus-gated
    /// timer stopped that frame is the last one — a fresh frozen smear no burst can reach.
    /// Standing the shader down closes that off: nothing can freeze, whenever the cursor moves.
    ///
    /// It stands down to a passthrough rather than to no shader at all, because ghostty stops
    /// updating its cursor uniforms when nothing is loaded — see `passthrough.glsl` for what
    /// that costs on the way back.
    private func startShaderSettle() {
        guard lastBehavior.cursorShader != nil, surfacePtr != nil else { return }
        cancelShaderSettle()
        applyShaderConfig(lastBehavior, animation: .always)
        hasPerSurfaceShaderConfig = true

        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var stoodDown = self.lastBehavior
            stoodDown.cursorShader = TerminalKitResources.passthroughShaderPath
            self.applyShaderConfig(stoodDown, animation: .whileFocused)
            self.shaderSettleWorkItem = nil
        }
        shaderSettleWorkItem = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shaderSettleDuration, execute: settle)
    }

    /// Put the app-global shape back on focus: the shader returns and animates while focused.
    /// Skipped entirely when this surface never deviated, so an ordinary focus costs nothing.
    private func restoreShader() {
        cancelShaderSettle()
        guard hasPerSurfaceShaderConfig else { return }
        applyShaderConfig(lastBehavior, animation: .whileFocused)
        hasPerSurfaceShaderConfig = false
    }

    private func applyShaderConfig(
        _ behavior: TerminalBehavior, animation: GhosttyConfigWriter.ShaderAnimation
    ) {
        guard let surfacePtr else { return }
        GhosttyApp.shared.updateSurfaceConfig(
            surfacePtr, theme: lastTheme, behavior: behavior, shaderAnimation: animation)
    }

    private func cancelShaderSettle() {
        shaderSettleWorkItem?.cancel()
        shaderSettleWorkItem = nil
    }

    public func terminate() {
        SecureInput.shared.removeScoped(secureInputID)
        // Before the surface is freed: the pending drop-back would otherwise fire against a
        // dangling pointer.
        cancelShaderSettle()
        guard let surfacePtr else { return }
        ghostty_surface_free(surfacePtr)
        self.surfacePtr = nil
        hostView.surfacePtr = nil
    }

    deinit {
        // Backstop for any release that skips terminate(): the surface holds a
        // passUnretained pointer back to us, so leaving it alive past our
        // deallocation would dangle that userdata on the next libghostty callback.
        // Nil the host view's pointer too (it can outlive us — its superview holds a
        // strong ref, our `owner` back-ref is weak) so a stray event after free doesn't
        // call ghostty_surface_* on freed memory. Mirrors terminate().
        SecureInput.shared.removeScoped(secureInputID)
        if let surfacePtr {
            ghostty_surface_free(surfacePtr)
            hostView.surfacePtr = nil
        }
    }

    /// Track focus for secure-input scoping. The host view calls this from its first-responder
    /// transitions so the global lock follows the pane you're actually typing in.
    func focusDidChange(_ focused: Bool) {
        if wantsSecureInput { SecureInput.shared.setScoped(secureInputID, focused: focused) }
    }

    public func paste(_ text: String) {
        guard let surfacePtr else { return }
        // utf8.count, not strlen: the text may contain an interior NUL and strlen
        // would truncate the paste there.
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

    public func scrollToBottom() {
        guard let surfacePtr else { return }
        let action = "scroll_to_bottom"
        _ = ghostty_surface_binding_action(surfacePtr, action, UInt(action.utf8.count))
    }

    func reportFocusWanted() { delegate?.surfaceWantsFocus(self) }
    func reportClose() { delegate?.surfaceWantsClose(self) }

    /// Translate an inbound libghostty action into a seam delegate event. Returns whether
    /// it was consumed.
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
            // OSC 777 / OSC 9 from a terminal app (e.g. Claude Code wanting the user) —
            // ghostty parses it and hands us title + body; the chrome toasts it.
            let notification = action.action.desktop_notification
            let title = notification.title.map { String(cString: $0) } ?? ""
            let body = notification.body.map { String(cString: $0) } ?? ""
            delegate?.surface(
                self, didPostNotification: TerminalNotification(title: title, body: body))
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            delegate?.surface(self, progressDidChange: Self.progress(action.action.progress_report))
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let code = Int32(action.action.child_exited.exit_code)
            // Defer to the next main-loop turn: the chrome frees this surface in
            // response, and doing that synchronously here — while libghostty is still
            // dispatching this action inside ghostty_app_tick — is a re-entrant
            // use-after-free. close_surface_cb defers for the same reason.
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
        case GHOSTTY_ACTION_SECURE_INPUT:
            setSecureInput(for: action.action.secure_input)
            return true
        default:
            return false
        }
    }

    /// Open a link libghostty resolved from a ⌘-click. Decode by `len` (not `strlen`) so an
    /// interior NUL can't truncate the URL, mirroring `paste()`. Runs on the main thread (like
    /// every `handle(_:)` case) and doesn't free the surface, so no deferred dispatch.
    private func openURL(_ openURL: ghostty_action_open_url_s) {
        guard let ptr = openURL.url else { return }
        let string = String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(openURL.len)), as: UTF8.self)
        // A scheme-less string is a file path, not a URL: `URL(string:)` accepts it but
        // `NSWorkspace.open` silently no-ops on it. Expand `~` and wrap it as a file URL so
        // clicked file paths actually open (ghostty-org/ghostty#8763).
        let url: URL
        if let candidate = URL(string: string), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: NSString(string: string).standardizingPath)
        }
        NSWorkspace.shared.open(url)
    }

    /// Update this surface's secure-input desire from a `GHOSTTY_ACTION_SECURE_INPUT` enum and
    /// hand it to `SecureInput.shared`, which owns the process-global lock (scoping it to focus
    /// and app-active state). TOGGLE flips our current desire.
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

    /// Map an OSC 9;4 progress report onto the seam's `TerminalProgress`.
    /// REMOVE clears the indicator (nil); `progress` is -1 when unreported.
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

/// Runs `body` with an optional C string that lives only for the call.
private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

private extension Array where Element == String {
    /// Vends a parallel array of C strings valid for the closure's duration.
    func withCStrings<T>(_ body: ([UnsafePointer<CChar>?]) -> T) -> T {
        func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>?], _ body: ([UnsafePointer<CChar>?]) -> T) -> T {
            if index == count { return body(acc) }
            return self[index].withCString { recurse(index + 1, acc + [$0], body) }
        }
        return recurse(0, [], body)
    }
}
