import AppKit
import AppLog
import GhosttyKit

/// libghostty-backed terminal surface, the sole backend.
///
/// Sits behind the `TerminalSurface` seam so the chrome never touches libghostty directly.
/// libghostty renders into a Metal layer it attaches to a host view we own, and the host forwards
/// every input (key / mouse / focus / size / scale) and pumps the shared app's event loop.
public final class GhosttySurface: NSObject, TerminalSurface {
    private let hostView = GhosttyHostView()
    var surfacePtr: ghostty_surface_t?
    private var lastTitle = ""
    private var lastCwd: URL?

    /// Whether libghostty has this surface in a password context. Secure keyboard entry is
    /// process-global, so we hand desire + focus to `SecureInput.shared` rather than driving it.
    private var wantsSecureInput = false
    private var secureInputID: ObjectIdentifier { ObjectIdentifier(self) }

    /// Retained so the settle-burst can regenerate this surface's config without the chrome
    /// handing them over again.
    private var lastTheme: TerminalTheme?
    private var lastBehavior: TerminalBehavior = .default

    /// The background this surface's terminal last reported rendering (OSC 11), or nil while it
    /// has never reported one. Outranks `lastTheme.background` wherever the chrome paints the fill
    /// behind and around the grid. A theme change deliberately does not clear it, see
    /// `applyAppearance`.
    public private(set) var backgroundOverride: TerminalColor?

    /// The font size this surface is actually running, which is not always the theme's. Every
    /// per-surface config push has to carry it: `Surface.updateConfig` resets the size of any
    /// surface libghostty has not marked `font_size_adjusted` to whatever the config says.
    private var lastFontSize: CGFloat?

    /// The color scheme libghostty last heard, so a repeat push is skipped. Not only an
    /// optimization: a push is answered with a config reload, and a reload can itself surface as a
    /// color change, so deriving the same scheme twice has to be silent or the loop has no bottom.
    private var lastReportedScheme: ghostty_color_scheme_e?

    /// Focus as libghostty last heard it, which tells a real change from a repeat. This is the
    /// *effective* focus, `paneFocused && isAppActive`, not either one alone.
    private(set) var lastFocused = true

    /// Whether this surface is the focused pane inside its own window. On its own it says nothing
    /// about whether the app is in front, which is why it isn't what libghostty gets told.
    private var paneFocused = true

    /// Whether the app is frontmost. Load-bearing beyond cursor blink: ghostty runs the
    /// custom-shader draw timer at 120fps for as long as its surface believes it is focused, and
    /// only `ghostty_surface_set_focus` moves that flag.
    private var isAppActive = true

    private var appActiveObservers: [NSObjectProtocol] = []

    /// The pending shader strip that follows a settle-burst. Cancelled by a refocus inside the
    /// window, and by `terminate`.
    private var shaderSettleWorkItem: DispatchWorkItem?

    /// Whether this surface runs a config that differs from the app-global one (mid-burst, or
    /// shader-stripped afterwards). Refocusing puts the app-global shape back.
    private var hasPerSurfaceShaderConfig = false

    /// How long a blurred surface keeps animating so its cursor tail can decay. The bundled
    /// shaders decay in 0.35s and 0.15s, so this clears the slower one with margin.
    private static let shaderSettleDuration: TimeInterval = 0.5

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { hostView }
    public var title: String { lastTitle }
    public var isFocused: Bool { hostView.window?.firstResponder === hostView }
    public var currentDirectory: URL? { lastCwd }

    /// Whether the shell has a running foreground command, via ghostty's needs-confirm-quit
    /// signal, which reports "cursor is not at a prompt" from shell integration (OSC 133 marks).
    ///
    /// A shell ghostty can't integrate (Apple's /bin/bash) has no prompt marks and reads busy,
    /// erring toward an extra close confirmation rather than losing live work. A backgrounded job
    /// leaves the shell at a prompt, so marks alone read as not busy while work is still running.
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

        // libghostty runs `command` via `bash -c` AND tokenizes the same string to detect the
        // shell for integration. That tokenizer strips double quotes only, so a single-quoted word
        // survives into arg0 and silently kills cwd tracking, prompt marks and `isBusy`.
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

        // A nil surface means `ghostty_surface_new` failed: the object stays alive but inert.
        guard surfacePtr != nil else {
            // On the next main-loop turn, not synchronously: callers wire the surface into their
            // own state around this call, and the chrome dispatches this callback by surface
            // identity, so a synchronous one would run before that wiring exists and be dropped.
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
        lastFontSize = config.fontSize ?? config.theme?.fontSize
        hostView.scrollMultiplier = (config.behavior ?? .default).scrollMultiplier

        // A fresh libghostty surface defaults to focused, and only `resignFirstResponder` flips it
        // false, so a surface that never becomes first responder (a hidden drawer, a background
        // pane) would keep an active cursor. Sync to the real state now that the surface exists.
        paneFocused = hostView.window?.firstResponder === hostView
        isAppActive = NSApp.isActive
        let bornFocused = paneFocused && isAppActive
        ghostty_surface_set_focus(surfacePtr, bornFocused)
        lastFocused = bornFocused
        // libghostty defaults a new surface to visible, so one born into a covered or minimized
        // window would draw until the first occlusion change moved it.
        hostView.syncOcclusion()
        // A surface born unfocused gets no blur to trigger the stand-down, and its shell reaching
        // a first prompt then freezes a smear with no timer running to decay it.
        //
        // Decided a turn later because nothing is focused yet at this point: the view becomes
        // first responder after `start` returns, so a pane about to be focused is indistinguishable
        // from a drawer that never will be.
        if !bornFocused {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.lastFocused else { return }
                self.startShaderSettle()
            }
        }

        applyLayerBacking(theme: config.theme, behavior: config.behavior ?? .default)
        syncColorScheme()

        // The host view may already be mounted, in which case its own `viewDidMoveToWindow`
        // ran before `surfacePtr` existed and couldn't push the display id.
        hostView.syncDisplayID()
        hostView.syncSizeAndScale()
        GhosttyApp.shared.tick()
    }

    /// Quote one word in DOUBLE quotes, escaping the four characters special inside a POSIX
    /// double-quoted string. Double rather than single because libghostty's shell-integration
    /// detector strips only double quotes, and `bash -c` honors the same rules.
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

    /// Fills the config's C-string pointers with buffers that live only for `body`, matching
    /// libghostty's requirement that they stay valid across `ghostty_surface_new`.
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
    /// Samples rather than snapshots because libghostty forks the shell well past
    /// `ghostty_surface_new`'s return, so a snapshot taken inside `start()` reliably finds nothing.
    /// One sampler serves every surface, and a start landing while one runs extends its deadline.
    private static func recordShellSessions() {
        ShellSessionLedger.shared.sample(for: 0.5, every: 0.025)
    }

    /// Re-apply appearance/behavior in place. libghostty config is app-global, so this re-themes
    /// every surface via `GhosttyApp.updateConfig`; the pieces scoped to this surface are applied
    /// here.
    ///
    /// A reported background survives this. `Termio.changeConfig` writes libghostty's `default`
    /// alone and leaves a program's color in place, so clearing our copy would put the chrome back
    /// on the theme while the terminal inside it stayed repainted.
    public func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {
        lastTheme = theme
        lastBehavior = behavior
        GhosttyApp.shared.updateConfig(theme: theme, behavior: behavior)
        // A stood-down surface runs its own config, which the app-global swap above does not
        // reach, so without this it keeps the old theme until something refocuses it.
        if hasPerSurfaceShaderConfig {
            if behavior.cursorShader == nil {
                // Turned off outright, so drop the override rather than pinning a passthrough onto
                // a surface meant to have no shader at all.
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
        // Last, because the push is answered synchronously with a config reload that re-pushes
        // whichever shape this surface is in, and the branch above is what decides it.
        syncColorScheme()
        if let surfacePtr { ghostty_surface_refresh(surfacePtr) }
    }

    /// Tell libghostty whether this surface reads as light or dark, so a program asking gets the
    /// truth instead of libghostty's `.light` default.
    ///
    /// Derived from the background rather than `effectiveAppearance`, which would answer "light"
    /// for a dark theme under a light system appearance. The source is the same
    /// `backgroundOverride ?? theme` that `applyLayerBacking` paints from, so the two answers
    /// cannot contradict each other.
    private func syncColorScheme() {
        guard let surfacePtr, let background = backgroundOverride ?? lastTheme?.background else {
            return
        }
        let scheme = background.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        guard scheme != lastReportedScheme else { return }
        lastReportedScheme = scheme
        ghostty_surface_set_color_scheme(surfacePtr, scheme)
    }

    /// Re-push this surface's current config so a conditional-state change reaches the terminal.
    ///
    /// libghostty raises this after `set_color_scheme` moves the scheme, and the re-derive is the
    /// only thing that carries the new state into `Termio`, which answers the color-scheme query.
    private func reapplySurfaceConfig() {
        guard let surfacePtr else { return }
        let pushed: Bool
        if hasPerSurfaceShaderConfig {
            // Mid-burst or already stood down, matching the shapes `applyAppearance` picks between.
            pushed =
                shaderSettleWorkItem != nil
                ? applyShaderConfig(lastBehavior, animation: .always)
                : applyShaderConfig(stoodDownBehavior, animation: .whileFocused)
        } else {
            pushed = GhosttyApp.shared.updateSurfaceConfig(
                surfacePtr, theme: lastTheme, behavior: lastBehavior,
                shaderAnimation: .whileFocused, fontSize: lastFontSize)
        }
        // The scheme only reaches `Termio` on the back of a config push, so drop the latch and let
        // the next `syncColorScheme` retry rather than short-circuit on one that never landed.
        if !pushed { lastReportedScheme = nil }
    }

    /// Set the font size in points, without touching the app-global config.
    ///
    /// Goes through libghostty's binding-action entry rather than `updateConfig`, which would be a
    /// synchronous file write/read/parse per distinct size. `set_font_size` marks the surface
    /// `font_size_adjusted`, after which this is the only thing that moves its size, so the chrome
    /// has to re-push after an `applyAppearance` rather than expect the theme's size to land.
    public func setFontSize(_ points: CGFloat) {
        lastFontSize = points
        performBindingAction("set_font_size:\(points)")
    }

    /// Perform one libghostty binding action on this surface by name. The action text is exactly
    /// what a `keybind =` line carries.
    ///
    /// `logsFailure` is for actions that answer "was there anything to do": navigating or ending a
    /// search that is not running both report false. Those are answers, not rejections.
    private func performBindingAction(_ action: String, logsFailure: Bool = true) {
        guard let surfacePtr else { return }
        let performed = action.withCString {
            ghostty_surface_binding_action(surfacePtr, $0, UInt(action.utf8.count))
        }
        if !performed && logsFailure {
            Log.error("GhosttySurface: libghostty rejected \(action)", category: .surface)
        }
    }

    /// The needle needs no escaping: libghostty splits on the *first* colon and takes the rest
    /// verbatim, so one holding colons, spaces or unicode arrives intact.
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

    /// How the surface's layer composites against the window behind it.
    ///
    /// At full opacity the layer is marked opaque over the terminal background: the host window is
    /// transparent for the vibrancy backdrop, so otherwise the compositor blends against that
    /// backdrop every frame, which tears under heavy TUI redraws and flashes light through redraw
    /// gaps. Below 1 that has to invert, and it is the whole of `background-alpha`: `isOpaque`
    /// tells Core Animation it need not blend, so ghostty's alpha would be discarded. The fill goes
    /// too, since it sits behind the drawable and would repaint at full strength underneath.
    private func applyLayerBacking(theme: TerminalTheme?, behavior: TerminalBehavior) {
        guard let layer = hostView.layer else { return }
        let isSolid = behavior.isBackgroundSolid
        let fill = backgroundOverride ?? theme?.background
        layer.isOpaque = isSolid
        layer.backgroundColor = isSolid ? (fill?.nsColor ?? .black).cgColor : nil
        // libghostty pins its contents top-left rather than stretching them, so whenever its
        // drawable is smaller than this layer the rest is uncovered: invisible behind an opaque
        // background, a see-through block without one, so a translucent surface stretches the last
        // frame instead until the next lands.
        layer.contentsGravity = isSolid ? .topLeft : .resize
    }

    public func focus() { hostView.window?.makeFirstResponder(hostView) }

    public func setFocused(_ focused: Bool) {
        handleFocusChange(focused)
    }

    /// Both pane-focus paths converge here: the chrome's `setFocused`, and the responder-chain
    /// transitions the host view reports. Either can be the only one to fire, so hanging the
    /// shader stand-down off one of them leaves a pane stuck on the passthrough.
    private func handleFocusChange(_ focused: Bool) {
        paneFocused = focused
        syncFocus()
    }

    /// The app came forward or went away. Panes keep their own focus across it, so this moves only
    /// the app half of the pair.
    private func handleAppActiveChange(_ active: Bool) {
        isAppActive = active
        syncFocus()
    }

    /// The single place libghostty is told whether this surface is focused. A pane counts as
    /// focused only while the app is also frontmost, which is what stops a focused pane in a
    /// background app animating at 120fps.
    private func syncFocus() {
        let focused = paneFocused && isAppActive
        if let surfacePtr { ghostty_surface_set_focus(surfacePtr, focused) }
        guard focused != lastFocused else { return }
        lastFocused = focused
        // Hangs off the effective value rather than `resignFirstResponder` because a pane keeps
        // first responder across a ⌘-Tab, which used to leave libghostty's release and our record
        // disagreeing. Below the dedupe on purpose: a pane can be re-synced unfocused while it
        // still has first responder, so clearing on a repeat would strand a held modifier.
        if !focused { hostView.forgetHeldModifiers() }
        if focused { restoreShader() } else { startShaderSettle() }
    }

    /// Registered at init rather than in `start`, so no activation change is missed. The handlers
    /// no-op against a nil surface.
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

    /// Let a blurred surface's cursor tail finish, then stand the real shader down.
    ///
    /// Two steps, because a blurred surface has two ways to show a tracer: the tail already in
    /// flight needs frames to decay, and `drawFrame` gates on visible rather than focused, so a
    /// cursor move on an unfocused pane still draws one frame that the stopped timer then freezes.
    /// It stands down to a passthrough rather than no shader, because ghostty stops updating its
    /// cursor uniforms when nothing is loaded.
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

    /// Put the app-global shape back on focus. Skipped when this surface never deviated, so an
    /// ordinary focus costs nothing.
    private func restoreShader() {
        cancelShaderSettle()
        guard hasPerSurfaceShaderConfig else { return }
        applyShaderConfig(lastBehavior, animation: .whileFocused)
        hasPerSurfaceShaderConfig = false
    }

    /// What a stood-down surface runs: the passthrough in place of the real shader, over the
    /// behavior last applied.
    private var stoodDownBehavior: TerminalBehavior {
        var stoodDown = lastBehavior
        stoodDown.cursorShader = TerminalKitResources.passthroughShaderPath
        return stoodDown
    }

    /// Carries `lastFontSize` like every other per-surface push, since the config libghostty is
    /// handed is what it clamps an unadjusted surface to.
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

    public func terminate() {
        SecureInput.shared.removeScoped(secureInputID)
        // Before the surface is freed: the pending drop-back and a late app-active change would
        // otherwise fire against a dangling pointer.
        cancelShaderSettle()
        removeAppActiveObservers()
        guard let surfacePtr else { return }
        // Last chance to see this shell alive. The sampler in `start()` has an unenforced bound, so
        // a pane opening on a loaded machine can fork after it stops, and a session never recorded
        // is one no teardown can sweep. Runs synchronously before the free, which closes the pty
        // and takes the shell down: deferring it past the free can miss the session entirely.
        ShellSessionLedger.shared.record(ShellSession.leaderChildren())
        ghostty_surface_free(surfacePtr)
        self.surfacePtr = nil
        hostView.surfacePtr = nil
        // After the free, which is what closes the pty: libghostty's SIGHUP to the shell's process
        // group goes first, and the sweep then takes what that group never covered.
        ShellSessionReaper.shared.reapOrphans()
    }

    deinit {
        // Backstop for any release that skips terminate(): the surface holds a passUnretained
        // pointer back to us, and the host view can outlive us, so a stray event after free would
        // otherwise call into freed memory.
        SecureInput.shared.removeScoped(secureInputID)
        removeAppActiveObservers()
        if let surfacePtr {
            ShellSessionLedger.shared.record(ShellSession.leaderChildren())
            ghostty_surface_free(surfacePtr)
            hostView.surfacePtr = nil
            ShellSessionReaper.shared.reapOrphans()
        }
    }

    /// The host view calls this from its first-responder transitions so the secure-input lock
    /// follows the pane you're actually typing in.
    func focusDidChange(_ focused: Bool) {
        if wantsSecureInput { SecureInput.shared.setScoped(secureInputID, focused: focused) }
        handleFocusChange(focused)
    }

    /// Ask libghostty's own keymap what it would do with this keystroke.
    ///
    /// Two binding flags decide the case, and the second is a trap. `CONSUMED` defaults set, and an
    /// unconsumed bind runs its action *and* hands the key on. `PERFORMABLE` does NOT make the call
    /// answer false: it is a pure set lookup that never evaluates whether the action would do
    /// anything, so it has to reach the caller as its own answer rather than folding into `claims`.
    public func disposition(of key: TerminalKey) -> ChordDisposition {
        guard let surfacePtr else { return .ignores }
        var flags = ghostty_binding_flags_e(0)
        var event = Self.ghosttyKey(key)
        // `text` has to outlive the call, so the pointer is formed here rather than inside the
        // builder, where it would dangle the moment the struct was returned.
        let matched = { (text: UnsafePointer<CChar>?) -> Bool in
            event.text = text
            return ghostty_surface_key_is_binding(surfacePtr, event, &flags)
        }
        guard key.text.map({ $0.withCString(matched) }) ?? matched(nil) else { return .ignores }
        if flags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue == 0 { return .claimsButPasses }
        if flags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue != 0 { return .mayClaim }
        return .claims
    }

    /// A seam key as libghostty's key event, minus the text the caller attaches. Only the fields
    /// the keymap matches on are set: `consumed_mods` is deliberately not among them, since
    /// `Binding.Set.getEvent` never reads it.
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
        // utf8.count, not strlen: the text may contain an interior NUL and strlen
        // would truncate the paste there.
        let byteCount = UInt(text.utf8.count)
        text.withCString { ghostty_surface_text(surfacePtr, $0, byteCount) }
    }

    /// libghostty maps this to `GHOSTTY_KEY_ENTER` and encodes the CR to the pty itself, the same
    /// path a real Enter takes (unbracketed, so a TUI submits on it).
    private static let returnKeyCode: UInt32 = 36

    public func submitLine() {
        guard let surfacePtr else { return }
        // A press then a release, as a real keystroke delivers: some line editors act on the
        // release. The field shapes mirror what a real Return keyDown builds.
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var key = ghostty_input_key_s()
            key.action = action
            key.keycode = Self.returnKeyCode
            key.mods = GHOSTTY_MODS_NONE
            key.consumed_mods = GHOSTTY_MODS_NONE
            key.unshifted_codepoint = UInt32(("\r" as Unicode.Scalar).value)
            key.composing = false
            "\r".withCString {
                key.text = $0; _ = ghostty_surface_key(surfacePtr, key)
            }
        }
    }

    public func copySelection() -> String? {
        guard let surfacePtr, ghostty_surface_has_selection(surfacePtr) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard let ptr = text.text else { return nil }
        return String(cString: ptr)
    }

    /// The grid's geometry, converted out of libghostty's backing pixels into points. A zero cell
    /// height means the surface has not been sized yet, and reporting it would put a zero-height
    /// band on the pane.
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

    /// The text on one viewport row. One row per call because the underlying read unwraps
    /// soft-wrapped rows, so a multi-row read comes back as logical lines and the caller's row
    /// index stops matching what it gets.
    public func text(viewportRow row: Int) -> String? {
        guard let metrics = cellMetrics, row >= 0, row < metrics.rows else { return nil }
        return text(
            in: TerminalViewportRange(
                startRow: row, startColumn: 0, endRow: row,
                endColumn: max(metrics.columns - 1, 0)))
    }

    /// A span of viewport cells, read in one call. The span cannot leave the grid and no argument
    /// here can make it: `Point.pin` clamps x to the column count and y to the grid height.
    public func text(in range: TerminalViewportRange) -> String? {
        guard let surfacePtr, let metrics = cellMetrics else { return nil }
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

    /// libghostty carries both search counts as optionals, marshalled to `-1` when empty. The
    /// selected index is **zero-based**, whatever the header comment above it says.
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

    /// Positive values scroll down in libghostty too, so the seam's sign convention passes
    /// straight through. The last two answer "was there anything to move to" rather than failing.
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

    /// libghostty reports false on the alternate screen, where clearing does nothing. An answer
    /// rather than a rejection.
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
            // Defer to the next main-loop turn: the chrome frees this surface in response, and
            // doing that while libghostty is still dispatching inside ghostty_app_tick is a
            // re-entrant use-after-free. This is the only path that closes a pane.
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
            // Edge-triggered, once on degrade and once on recovery. An unhealthy renderer is a
            // silently black pane, so log it loudly enough to tell from a hung shell in a report.
            if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY {
                Log.info("GhosttySurface: renderer recovered", category: .surface)
            } else {
                Log.error(
                    "GhosttySurface: renderer unhealthy, pane may render black",
                    category: .surface)
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            // Emitted whenever the viewport moves OR the buffer grows, so it arrives on ordinary
            // output too, not only on a scroll.
            let bar = action.action.scrollbar
            delegate?.surface(
                self,
                scrollPositionDidChange: TerminalScrollPosition(
                    total: Int(bar.total), offset: Int(bar.offset), viewport: Int(bar.len)))
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            // libghostty's own start-search binds. Neither starts a search: they ask the apprt for
            // a find bar, seeded with the selection. We never send them, but they are live
            // keybinds in every surface, so without this case they do nothing at all.
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

    /// React to a dynamic color a program set with OSC 4/10/11/12.
    ///
    /// **This is not what makes the terminal honor them.** libghostty writes the color into
    /// `terminal.colors` before it sends this and its renderer draws from there, so the grid
    /// already follows the program. The action exists so the app around the terminal can match:
    /// the pane's own fill, and nothing else. Foreground, cursor and palette slots are drawn by the
    /// terminal itself, so they are consumed and dropped.
    private func applyColorChange(_ change: ghostty_action_color_change_s) {
        guard case .background(let color) = Self.effect(of: change) else { return }
        backgroundOverride = color
        applyLayerBacking(theme: lastTheme, behavior: lastBehavior)
        delegate?.surface(self, backgroundDidChange: color)
        // Deferred a turn, and that is load-bearing: this runs inside libghostty's own mailbox
        // drain, and the push ends in `ghostty_app_tick`, which drains it again. Called inline, a
        // second queued color change would complete inside this one and then be overwritten by
        // this frame's older color as it unwound.
        DispatchQueue.main.async { [weak self] in self?.syncColorScheme() }
    }

    /// What a `COLOR_CHANGE` means to the chrome. Pure, so the mapping is tested without a live
    /// surface.
    ///
    /// **The color is carried through as-is, including a reset.** libghostty does not restore on a
    /// reset: `DynamicRGB.reset` is `override = default`, not `override = null`, so once a program
    /// has touched OSC 11 the grid is pinned to a concrete RGB no later theme change can move.
    /// Recognising the theme's own color and dropping the override would move the chrome off a
    /// grid that stayed put.
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

    /// Map a `MOUSE_OVER_LINK` payload onto the seam's hovered-link value. libghostty sends an
    /// empty string when the pointer leaves a link; the seam carries that as nil. Decode by `len`
    /// so an interior NUL can't truncate the URL.
    static func hoveredLink(_ link: ghostty_action_mouse_over_link_s) -> String? {
        guard let ptr = link.url, link.len > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(link.len)), as: UTF8.self)
    }

    /// Open a link libghostty resolved from a ⌘-click. Decode by `len` so an interior NUL can't
    /// truncate the URL.
    private func openURL(_ openURL: ghostty_action_open_url_s) {
        guard let ptr = openURL.url else { return }
        let string = String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(openURL.len)), as: UTF8.self)
        // A scheme-less string is a file path, not a URL: `URL(string:)` accepts it but
        // `NSWorkspace.open` silently no-ops on it (ghostty-org/ghostty#8763).
        let url: URL
        if let candidate = URL(string: string), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: NSString(string: string).standardizingPath)
        }
        NSWorkspace.shared.open(url)
    }

    /// Hand this surface's secure-input desire to `SecureInput.shared`, which owns the
    /// process-global lock. TOGGLE flips the current desire.
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

    /// Map an OSC 9;4 progress report onto the seam's `TerminalProgress`. REMOVE clears the
    /// indicator; `progress` is -1 when unreported.
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
