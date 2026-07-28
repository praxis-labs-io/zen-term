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

    /// The background this surface's terminal last reported rendering (OSC 11), or nil while it
    /// has never reported one and the theme's still stands. It outranks `lastTheme.background`
    /// wherever the chrome paints the fill behind and around the grid; the per-surface ghostty
    /// config `applyShaderConfig` writes still carries the plain theme, which is harmless because
    /// a config change only moves libghostty's `default` and the reported color wins over it.
    /// A theme change deliberately does not clear this — see `applyAppearance`.
    public private(set) var backgroundOverride: TerminalColor?

    /// Focus as libghostty last heard it, which is what tells a real focus change from a repeat.
    /// `start` sets it to what it actually told libghostty; until then it matches libghostty's
    /// own default (`flags.focused = true`, "up to the apprt to set the correct value").
    ///
    /// This is the *effective* focus — `paneFocused && isAppActive`, not either one alone.
    private(set) var lastFocused = true

    /// Whether this surface is the focused pane inside its own window, from the responder chain
    /// and the chrome's `setFocused`. On its own it says nothing about whether the app is in
    /// front, which is why it isn't what libghostty gets told.
    private var paneFocused = true

    /// Whether the app is frontmost. Load-bearing for more than cursor blink: ghostty runs the
    /// custom-shader draw timer at `DRAW_INTERVAL` (8ms, 120fps) for as long as its surface
    /// believes it is focused (`renderer/Thread.zig`, `syncDrawTimer`), and only
    /// `ghostty_surface_set_focus` moves that flag — app-level focus doesn't reach it. Without
    /// this, switching apps left the focused pane animating a shader nobody could see, at 120fps,
    /// until you came back (ZEN-271).
    private var isAppActive = true

    /// NSApp activate/resign observers feeding `isAppActive`.
    private var appActiveObservers: [NSObjectProtocol] = []

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
    /// A backgrounded job leaves the shell sitting at a prompt, so prompt marks alone read as
    /// not busy while real work is still running.
    public var isBusy: Bool {
        guard let surfacePtr else { return false }
        return ghostty_surface_needs_confirm_quit(surfacePtr)
    }

    public override init() {
        super.init()
        hostView.owner = self
        observeAppActive()
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

        // Below the nil guard: a failed surface forks no shell, so there is nothing to record.
        Self.recordShellSessions()

        lastTheme = config.theme
        lastBehavior = config.behavior ?? .default
        hostView.scrollMultiplier = (config.behavior ?? .default).scrollMultiplier

        // A fresh libghostty surface defaults to focused=true, and only `resignFirstResponder`
        // ever flips it false — so a surface that never becomes first responder (a hidden drawer,
        // a background pane, a dismissed tool float) would keep an active/blinking cursor. Sync
        // focus to the real first-responder and app-active state now that the surface exists,
        // so a surface born while the app is in the background starts quiet. This also covers a view that
        // became first responder before `surfacePtr` was set (the `becomeFirstResponder` true
        // was skipped under its `if let surfacePtr` guard).
        paneFocused = hostView.window?.firstResponder === hostView
        isAppActive = NSApp.isActive
        let bornFocused = paneFocused && isAppActive
        ghostty_surface_set_focus(surfacePtr, bornFocused)
        // Track what we just told libghostty, so the first real focus change is measured against
        // the truth rather than against an assumption.
        lastFocused = bornFocused
        // libghostty defaults a new surface to visible, so a surface born into a covered or
        // minimized window would draw until the first occlusion change moved it.
        hostView.syncOcclusion()
        // A surface born unfocused gets no blur to trigger the stand-down, and it's the case that
        // shows the tracer worst: the drawers of a new workspace land unfocused and their shells
        // then reach a first prompt, moving the cursor with no timer running to decay the smear.
        //
        // Decided a turn later, not here, because at this point NOTHING is focused yet — the view
        // becomes first responder after `start` returns, so a pane that is about to be focused is
        // indistinguishable from a drawer that never will be. Standing down immediately meant every
        // surface stood down and then restored, a pair of `GhosttyApp.updateSurfaceConfig` calls
        // per pane that bought nothing. Those are cheap now that configs are cached; before that
        // they were a synchronous file write, read and parse each, on the main thread, which a
        // workspace open paid by the dozen. One turn is far inside the window
        // that matters: what this guards against is a shell reaching its first prompt, which is
        // orders of magnitude slower.
        if !bornFocused {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.lastFocused else { return }
                self.startShaderSettle()
            }
        }

        applyLayerBacking(theme: config.theme, behavior: config.behavior ?? .default)

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

    /// Note the shell sessions this app is running, so teardown has something to sweep.
    ///
    /// It samples rather than taking one snapshot because libghostty forks the shell well past
    /// `ghostty_surface_new`'s return, and `setsid()` then runs in the child, concurrently with
    /// us — a snapshot taken anywhere inside `start()` reliably finds nothing. It records every
    /// session it sees, not "this surface's", which is not a thing anything here can identify
    /// (see `ShellSessionLedger`).
    /// One sampler serves every surface. What it records is surface-independent, so a workspace
    /// opening eight panes would otherwise run eight identical samplers: 160 process-table walks
    /// and eight dispatch threads parked in `Thread.sleep`. A start landing while one is already
    /// running extends its deadline instead of starting another.
    private static func recordShellSessions() {
        ShellSessionLedger.shared.sample(for: 0.5, every: 0.025)
    }

    /// Re-apply appearance/behavior in place. libghostty config is app-global, so this
    /// re-themes every surface via `GhosttyApp.updateConfig` (deduped there); the pieces
    /// scoped to this surface (layer backing, scroll multiplier, redraw) are applied here.
    /// A reported background survives this. `Termio.changeConfig` writes libghostty's `default`
    /// alone and leaves the color a program set in place, so the grid stays where the terminal put
    /// it. Clearing our copy here would put the chrome back on the theme while the terminal inside
    /// it stayed repainted. This holds after an OSC 111 too: a reset pins `override` to the
    /// then-current default rather than clearing it, so the grid never returns to a moving theme.
    public func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {
        lastTheme = theme
        lastBehavior = behavior
        GhosttyApp.shared.updateConfig(theme: theme, behavior: behavior)
        // A stood-down surface runs its own config, which the app-global swap above does not
        // reach, so without this it keeps the old theme until something happens to refocus it.
        // Re-apply whichever shape it is currently in, rebuilt from the theme and behavior that
        // just landed. Raised by review on the ZEN-237 PR and left open there; ZEN-271 widened it
        // by standing a pane down when the app deactivates, not only when the pane blurs.
        if hasPerSurfaceShaderConfig {
            if behavior.cursorShader == nil {
                // The shader was turned off outright. The app-global config it just picked up has
                // none either, so drop the override rather than pinning a passthrough onto a
                // surface that is meant to have no shader at all.
                cancelShaderSettle()
                hasPerSurfaceShaderConfig = false
            } else if shaderSettleWorkItem != nil {
                applyShaderConfig(behavior, animation: .always)  // mid-burst, still decaying
            } else {
                applyShaderConfig(stoodDownBehavior, animation: .whileFocused)  // already stood down
            }
        }
        applyLayerBacking(theme: theme, behavior: behavior)
        hostView.scrollMultiplier = behavior.scrollMultiplier
        if let surfacePtr { ghostty_surface_refresh(surfacePtr) }
    }

    /// How the surface's layer composites against the window behind it. Three entry points run
    /// this: `start(_:)` once libghostty has made `hostView` layer-hosting, `applyAppearance` on
    /// every live config change, and `applyColorChange` when a program repaints the background
    /// outside a config change at all.
    ///
    /// At full opacity the layer is marked opaque over the terminal background. The host window
    /// is transparent for the vibrancy backdrop, so otherwise the compositor blends this layer
    /// against that backdrop every frame — which tears under heavy TUI redraws and flashes the
    /// (light) backdrop through any redraw gap. Opaque makes it composite as a solid surface, and
    /// gaps show the terminal bg rather than the window behind it.
    ///
    /// Below 1 that has to invert, and it is the whole of `background-alpha` (ZEN-282): `isOpaque`
    /// tells Core Animation it need not blend, so the alpha ghostty renders is discarded and
    /// dialling the ghostty key alone changes nothing on screen. The background fill has to go
    /// too — it sits behind the drawable and would repaint the terminal background at full
    /// strength under ghostty's own alpha-blended one.
    ///
    /// A cursor shader doesn't move this either way. ZEN-188 carved out an exception — drop the
    /// layer out of opaque whenever a shader is on, so the alpha ghostty's shader pass writes
    /// reaches Core Animation instead of being ignored — against an alt-screen white flash. That
    /// flash was root-caused by reading the code, never reproduced with the shaders that shipped,
    /// and the guard went in preemptively alongside them, so its own "no flash across
    /// vim/less/fzf" verification only ever ran with the guard already in place. Re-tested with it
    /// removed (backdrop-alpha 0.5, cursor_warp, 5K) across vim, nvim, less, fzf and lazygit: no
    /// flash. It also bought nothing — the window is translucent below backdrop-alpha 1
    /// regardless, so the compositor blends it either way (ZEN-271).
    ///
    /// The fill takes `backgroundOverride` ahead of the theme, so a surface a program has
    /// repainted (OSC 11) doesn't flash the theme color through a redraw gap or the uncovered
    /// strip a resize leaves — the two colors have to be the same one for this to hide anything.
    private func applyLayerBacking(theme: TerminalTheme?, behavior: TerminalBehavior) {
        guard let layer = hostView.layer else { return }
        let isSolid = behavior.isBackgroundSolid
        let fill = backgroundOverride ?? theme?.background
        layer.isOpaque = isSolid
        layer.backgroundColor = isSolid ? (fill?.nsColor ?? .black).cgColor : nil
        // libghostty pins its contents top-left rather than stretching them, so whenever its
        // drawable is smaller than this layer — every resize, and the stretch between a
        // surface's first layout and its final one — the rest of the layer is uncovered. That is
        // invisible behind the opaque background above, and a see-through block without it, so a
        // translucent surface stretches the last frame instead until the next one lands (ZEN-282).
        layer.contentsGravity = isSolid ? .topLeft : .resize
    }

    public func focus() { hostView.window?.makeFirstResponder(hostView) }

    public func setFocused(_ focused: Bool) {
        handleFocusChange(focused)
    }

    /// Both pane-focus paths converge here: the chrome's `setFocused`, and the responder-chain
    /// transitions the host view reports through `focusDidChange`. Either can be the only one
    /// to fire — a click focuses a pane through the responder chain — so hanging the shader
    /// stand-down off just one of them leaves a pane stuck on the passthrough, its shader
    /// silently dead until some later focus cycle happens to resync it.
    private func handleFocusChange(_ focused: Bool) {
        paneFocused = focused
        syncFocus()
    }

    /// The app came forward or went away. Panes keep their own focus across it — the pane you
    /// left is the pane you come back to — so this moves only the app half of the pair.
    private func handleAppActiveChange(_ active: Bool) {
        isAppActive = active
        syncFocus()
    }

    /// The single place libghostty is told whether this surface is focused, from both halves.
    /// A pane is focused only while the app is also frontmost: a focused pane in a background
    /// app is exactly the case that used to animate at 120fps behind another app's window.
    ///
    /// The shader work is deduped because both halves repeat themselves — the chrome re-sends
    /// every surface's focus state on any focus change, and a stand-down per repeat would
    /// re-shape idle panes for nothing. libghostty dedupes its own side, so the forwarding
    /// stays unconditional.
    private func syncFocus() {
        let focused = paneFocused && isAppActive
        if let surfacePtr { ghostty_surface_set_focus(surfacePtr, focused) }
        guard focused != lastFocused else { return }
        lastFocused = focused
        if focused { restoreShader() } else { startShaderSettle() }
    }

    /// Keep `isAppActive` tracking NSApp. Registered at init, not in `start`, so there is no
    /// window in which an activation change is missed — the handlers no-op against a nil surface.
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
            self.applyShaderConfig(self.stoodDownBehavior, animation: .whileFocused)
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

    /// What a stood-down surface runs: the passthrough in place of the real shader, over the
    /// behavior last applied. Shared by the settle and by `applyAppearance`, which has to rebuild
    /// the same shape when the theme moves under a surface that is already stood down.
    private var stoodDownBehavior: TerminalBehavior {
        var stoodDown = lastBehavior
        stoodDown.cursorShader = TerminalKitResources.passthroughShaderPath
        return stoodDown
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
        // Before the surface is freed: the pending drop-back and a late app-active change would
        // otherwise fire against a dangling pointer.
        cancelShaderSettle()
        removeAppActiveObservers()
        guard let surfacePtr else { return }
        // Last chance to see this shell alive. The sampler in `start()` is a fast path with an
        // unenforced bound: libghostty forks on its io thread, so a pane opening on a loaded
        // machine can fork after the sampler stops, and a session never recorded is one no
        // teardown can ever sweep — the ZEN-269 leak back, silently. Here the shell provably
        // still exists, and a sibling caught by the same snapshot is alive and so unsweepable.
        ShellSessionLedger.shared.record(ShellSession.leaderChildren())
        ghostty_surface_free(surfacePtr)
        self.surfacePtr = nil
        hostView.surfacePtr = nil
        // After the free, which is what closes the pty: libghostty's own SIGHUP to the shell's
        // process group goes first, and the sweep then takes what that group never covered — the
        // background jobs, the children parked in their own groups (ZEN-269). The free is also
        // what takes this session's leader down, which is how the sweep knows what to reach for.
        ShellSessionReaper.shared.reapOrphans()
    }

    deinit {
        // Backstop for any release that skips terminate(): the surface holds a
        // passUnretained pointer back to us, so leaving it alive past our
        // deallocation would dangle that userdata on the next libghostty callback.
        // Nil the host view's pointer too (it can outlive us — its superview holds a
        // strong ref, our `owner` back-ref is weak) so a stray event after free doesn't
        // call ghostty_surface_* on freed memory. Mirrors terminate().
        SecureInput.shared.removeScoped(secureInputID)
        removeAppActiveObservers()
        if let surfacePtr {
            // Same last-chance record as `terminate()`: a surface released without ever being
            // terminated still has to leave a sweepable session behind if the start sampler
            // missed its fork.
            ShellSessionLedger.shared.record(ShellSession.leaderChildren())
            ghostty_surface_free(surfacePtr)
            hostView.surfacePtr = nil
            ShellSessionReaper.shared.reapOrphans()
        }
    }

    /// Track focus for secure-input scoping. The host view calls this from its first-responder
    /// transitions so the global lock follows the pane you're actually typing in.
    func focusDidChange(_ focused: Bool) {
        if wantsSecureInput { SecureInput.shared.setScoped(secureInputID, focused: focused) }
        handleFocusChange(focused)
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

    public func setSizeSyncSuspended(_ suspended: Bool) {
        hostView.setSizeSyncSuspended(suspended)
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
        case GHOSTTY_ACTION_COLOR_CHANGE:
            applyColorChange(action.action.color_change)
            return true
        default:
            return false
        }
    }

    /// React to a dynamic color a program set with OSC 4/10/11/12 (or reset with OSC 110–112).
    ///
    /// **This is not what makes the terminal honor them.** libghostty writes the color into
    /// `terminal.colors` before it sends this, and its renderer draws from there, so the grid
    /// already follows the program whether we handle this or not. The action exists so the app
    /// around the terminal can match — which is where the decision is (ZEN-23): the pane's own
    /// fill matches, and nothing else does. Every chrome role stays `Theme.current` (ZEN-27), so
    /// a program can recolor its own pane but never the frame around it.
    ///
    /// Only the background reaches anything. The foreground, the cursor and the 256 palette slots
    /// are drawn by the terminal itself and no chrome surface repeats them, so they are consumed
    /// and dropped rather than left to fall through as an unhandled action.
    private func applyColorChange(_ change: ghostty_action_color_change_s) {
        guard case .background(let color) = Self.effect(of: change) else { return }
        backgroundOverride = color
        applyLayerBacking(theme: lastTheme, behavior: lastBehavior)
        delegate?.surface(self, backgroundDidChange: color)
    }

    /// What a `COLOR_CHANGE` means to the chrome. Pure, so the mapping is tested without a live
    /// surface.
    ///
    /// **The color is carried through as-is, including a reset.** A reset (OSC 111) arrives as an
    /// ordinary change carrying the color libghostty is restoring, with nothing to tell it apart
    /// from a program setting that same color, so the obvious move is to recognise the theme's own
    /// background and hand back "no override". That is wrong, because libghostty does not restore
    /// on a reset: `DynamicRGB.reset` is `override = default`, not `override = null`
    /// (`terminal/color.zig`), and `Termio.changeConfig` then writes `default` alone. So once a
    /// program has touched OSC 11 the grid is pinned to a concrete RGB that no later theme change
    /// can move. Dropping the override would move the chrome off a grid that stayed put, which is
    /// the mismatch this ticket exists to remove. Mirroring the reported color keeps the pane
    /// matched to its own terminal in every order: both follow the program, and after a theme
    /// change both stay where the terminal left them.
    static func effect(of change: ghostty_action_color_change_s) -> ColorChangeEffect {
        guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return .ignored }
        return .background(TerminalColor(red: change.r, green: change.g, blue: change.b))
    }

    /// The chrome-visible consequence of a `COLOR_CHANGE`.
    enum ColorChangeEffect: Equatable {
        /// The background the terminal now reports rendering.
        case background(TerminalColor)
        /// Foreground, cursor or a palette slot: the terminal draws it, the chrome does not.
        case ignored
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
