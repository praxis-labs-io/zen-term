import AppKit
import AppLog
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

    /// The font size this surface is actually running, which is not always the theme's.
    ///
    /// A pane opened while the session size is stepped is born at that size (ZEN-224), and
    /// `setFontSize` moves it afterwards. Every per-surface config push has to carry this, because
    /// `Surface.updateConfig` resets the size of any surface libghostty has not marked
    /// `font_size_adjusted` to whatever the pushed config says. Nil until `start` has run.
    private var lastFontSize: CGFloat?

    /// The color scheme libghostty last heard from us, so a repeat push is skipped (ZEN-307).
    ///
    /// Not only an optimization. `applyColorChange` pushes the scheme, a push libghostty answers
    /// with a config reload, and a config reload can itself surface as a color change. Deriving
    /// the same scheme twice in a row therefore has to be silent, or that round trip has no
    /// bottom. libghostty dedupes internally too (`colorSchemeCallback` returns early when the
    /// scheme has not moved), so this is belt and braces on a loop that would be expensive.
    private var lastReportedScheme: ghostty_color_scheme_e?

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
        // What libghostty was handed as `cfg.font_size`, so a later per-surface config push can
        // carry it rather than reset the pane to the theme's size (ZEN-224).
        lastFontSize = config.fontSize ?? config.theme?.fontSize
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
        syncColorScheme()

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
        // Last, because the push is answered synchronously with a config reload that re-pushes
        // whichever shape this surface is currently in, and the branch above is what decides it.
        syncColorScheme()
        if let surfacePtr { ghostty_surface_refresh(surfacePtr) }
    }

    /// Tell libghostty whether this surface reads as light or dark, so a program asking
    /// (DSR `CSI ? 996 n`, mode 2031) gets the truth instead of libghostty's `.light` default
    /// (ZEN-307).
    ///
    /// Derived from the background rather than `NSApplication.effectiveAppearance`, which is what
    /// Ghostty.app reads. The chrome is theme-driven, not appearance-driven (ZEN-91), so
    /// `effectiveAppearance` would answer "light" for a dark theme under a light system
    /// appearance. The source is the same `backgroundOverride ?? theme` that `applyLayerBacking`
    /// paints from, so a program that repaints its own background with OSC 11 also moves what the
    /// pane reports, and the two answers can never contradict each other.
    ///
    /// Only half the fix. The scheme reaches the report through a config re-derive, which is what
    /// `GHOSTTY_ACTION_RELOAD_CONFIG` below is for, and that re-derive only carries it because
    /// `GhosttyConfigWriter` marks the theme conditional.
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
    /// libghostty raises this after `set_color_scheme` moves the scheme, and the re-derive it asks
    /// for is the only thing that carries the new state into `Termio`, which is what answers the
    /// color-scheme query. Ignoring it leaves the surface knowing its scheme and still reporting
    /// the old one.
    ///
    /// `soft` is not branched on, unlike Ghostty.app, which re-reads the user's config file for a
    /// hard reload. There is no such file here: the config is generated from the chrome's theme,
    /// so re-pushing what this surface currently runs is the whole of either job.
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
        // The scheme only reaches `Termio` on the back of a config push, so a push that never
        // happened leaves this surface reporting the old one. Drop the latch so the next
        // `syncColorScheme` retries instead of short-circuiting on a scheme that never landed.
        if !pushed { lastReportedScheme = nil }
    }

    /// Set the font size in points, without touching the app-global config.
    ///
    /// Goes through libghostty's binding-action entry rather than `updateConfig`, which is what
    /// makes it cheap enough for a held ⌘+ (ZEN-224): `ghostty_surface_binding_action` parses the
    /// action and performs it inline, where writing a config would be a synchronous file
    /// write/read/parse on the main thread for every distinct size.
    ///
    /// `set_font_size` marks the surface `font_size_adjusted`, and libghostty then leaves its font
    /// size alone across config reloads ("we assume the user wants a specific size"). So this is
    /// the *only* thing that moves a surface's size once it has been called, and the chrome has to
    /// re-push after an `applyAppearance` rather than expect the theme's size to land.
    public func setFontSize(_ points: CGFloat) {
        lastFontSize = points
        performBindingAction("set_font_size:\(points)")
    }

    /// Perform one libghostty binding action on this surface by name.
    ///
    /// The action text is exactly what a `keybind =` line carries, and libghostty parses it the
    /// same way, so anything in its surface-scope action list is reachable from here. A rejected
    /// action is logged rather than thrown: every caller is a keystroke, and a keystroke that
    /// does nothing is the right failure.
    ///
    /// `logsFailure` is for the actions that answer "was there anything to do": navigating or
    /// ending a search that is not running both report false, and so does an empty needle with no
    /// search behind it. Those are answers, not rejections.
    private func performBindingAction(_ action: String, logsFailure: Bool = true) {
        guard let surfacePtr else { return }
        let performed = action.withCString {
            ghostty_surface_binding_action(surfacePtr, $0, UInt(action.utf8.count))
        }
        if !performed && logsFailure {
            Log.error("GhosttySurface: libghostty rejected \(action)", category: .surface)
        }
    }

    /// The needle goes over the same binding-action channel as everything else, and needs no
    /// escaping: libghostty splits on the *first* colon and takes the rest verbatim, so a needle
    /// holding colons, spaces or unicode arrives intact.
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
        // Both halves have to retire the modifier ledger, which is why it hangs off the effective
        // value rather than off `resignFirstResponder`. A pane keeps first responder across a
        // ⌘-Tab, so the app half alone used to leave libghostty's release and our record
        // disagreeing on every switch away.
        //
        // Below the dedupe on purpose. libghostty's `focusCallback` returns early when focus has
        // not moved and releases nothing, and a pane can be re-synced unfocused while it still
        // has first responder (scroll mode renders it blurred), so clearing on a repeat would
        // strand a modifier libghostty is still holding.
        if !focused { hostView.forgetHeldModifiers() }
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

    /// Carries `lastFontSize` like every other per-surface push. Without it a settle-burst on a
    /// pane opened at a stepped size would reset that pane to the theme's size (ZEN-224), since
    /// the config libghostty is handed is what it clamps an unadjusted surface to.
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
        // Last chance to see this shell alive. The sampler in `start()` is a fast path with an
        // unenforced bound: libghostty forks on its io thread, so a pane opening on a loaded
        // machine can fork after the sampler stops, and a session never recorded is one no
        // teardown can ever sweep — the ZEN-269 leak back, silently. Here the shell provably
        // still exists, and a sibling caught by the same snapshot is alive and so unsweepable.
        //
        // The walk deliberately runs synchronously, before the free — in practice on the main
        // thread, where it cost ~0.2ms against an ~850-process table (measured, ZEN-314) and is
        // dominated by the free below. It cannot be deferred past the free: the free closes the
        // pty and takes the shell down, so a late snapshot can miss the session entirely, which
        // is the same leak. Don't move it without a new record path that sees the shell before
        // the pty closes.
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

    /// Ask libghostty's own keymap what it would do with this keystroke.
    ///
    /// `ghostty_surface_key_is_binding` answers against the surface's live config and fills a
    /// `ghostty_binding_flags_e` bitfield for the bind it matched. Two of those flags decide the
    /// case, and the second one is a trap:
    ///
    /// * **`CONSUMED`** defaults set. An `unconsumed` bind runs its action *and* still hands the
    ///   key to the program, so reading the return alone would report that chord as taken.
    /// * **`PERFORMABLE`** does NOT make the call answer false. It is a pure set lookup:
    ///   `Surface.keyEventIsBinding` returns the entry's flags and never evaluates whether the
    ///   action would do anything, which upstream's own comment on it says outright. The
    ///   evaluation happens later, in `keyCallback`, which falls through to encoding the key when
    ///   a performable action was not performed. So the flag has to reach the caller as its own
    ///   answer rather than being folded into `claims`.
    ///
    /// The two never appear together in the shipped keybinds, and if that ever changes,
    /// `unconsumed` is the safer report: the program receives the key either way.
    ///
    /// Inert without a surface, which is the honest answer: no surface, no keymap to ask.
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

    /// A seam key as libghostty's key event, minus the text the caller attaches.
    ///
    /// Only the fields the keymap matches on are set. `consumed_mods` is deliberately not among
    /// them: `Binding.Set.getEvent` matches on the mods, the text and the unshifted codepoint and
    /// never reads it, so setting it here would be a second copy of `ghosttyKeyEvent`'s
    /// translation heuristic that nothing exercises.
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

    /// The macOS virtual keycode for Return — libghostty maps it to `GHOSTTY_KEY_ENTER` and encodes
    /// the CR to the pty itself, the same path a real Enter keypress takes (unbracketed, so a TUI
    /// submits on it). Below the seam, so knowing an AppKit keycode here is fine.
    private static let returnKeyCode: UInt32 = 36

    public func submitLine() {
        guard let surfacePtr else { return }
        // A press then a release, as a real keystroke delivers — some line editors act on the release.
        // The field shapes mirror what a real Return keyDown builds in `GhosttyHostView.ghosttyKeyEvent`
        // (text = "\r", unshifted_codepoint = the CR scalar), so libghostty encodes it to the pty the same
        // way the live key path does rather than through a shape it's never handed in practice.
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

    /// The grid's geometry, converted out of libghostty's backing pixels into points.
    ///
    /// Every `_px` field is in the same units the chrome pushed through
    /// `ghostty_surface_set_size`, which is `convertToBacking` of the view's bounds. So this
    /// divides by the same backing scale to get back to the points AppKit lays views out in.
    /// A zero cell height means the surface has not been sized yet, and reporting it would put a
    /// zero-height band on the pane.
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

    /// The text on one viewport row.
    ///
    /// One row per call because `ghostty_surface_read_text` goes through `selectionString`, which
    /// sets `unwrap = true` and joins soft-wrapped rows: a multi-row read comes back as logical
    /// lines, so the caller's row index stops matching what it gets. A single-row selection has
    /// nothing to unwrap into.
    public func text(viewportRow row: Int) -> String? {
        guard let metrics = cellMetrics, row >= 0, row < metrics.rows else { return nil }
        return text(
            in: TerminalViewportRange(
                startRow: row, startColumn: 0, endRow: row,
                endColumn: max(metrics.columns - 1, 0)))
    }

    /// A span of viewport cells, read in one call.
    ///
    /// The span cannot leave the grid and no argument here can make it: `Point.pin` clamps x to the
    /// column count and y to the grid height, in the same two lines, whichever tag it carries.
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
    /// selected index is **zero-based**, whatever the header comment above it says: the engine
    /// pushes its raw index and ghostty's own UI renders `selected + 1`.
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

    /// Positive `lines`/`pageFraction` scroll down in libghostty too (`Binding.zig`: "Positive
    /// values scroll downwards"), so the seam's sign convention passes straight through. Its
    /// `jump_to_prompt` counts the same way, positive toward newer output.
    ///
    /// The last two answer "was there anything to move to": `scroll_to_selection` reports false
    /// with nothing selected, and `jump_to_prompt` with no prompt that far through the buffer.
    /// Those are answers, not rejections.
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

    /// libghostty reports false on the alternate screen, where clearing does nothing and the
    /// full-screen program keeps its display. An answer rather than a rejection.
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
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            delegate?.surface(
                self, commandDidFinish: Self.commandResult(action.action.command_finished))
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let code = Int32(action.action.child_exited.exit_code)
            // Defer to the next main-loop turn: the chrome frees this surface in
            // response, and doing that synchronously here — while libghostty is still
            // dispatching this action inside ghostty_app_tick — is a re-entrant
            // use-after-free. This is the only path that closes a pane; close_surface_cb
            // is a documented no-op (see GhosttyApp).
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
            // Edge-triggered: libghostty raises this once when the Metal renderer degrades and
            // once when it recovers. An unhealthy renderer is a silently black pane, so log it
            // loudly enough to tell apart from a hung shell in a bug report (ZEN-309).
            if action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY {
                Log.info("GhosttySurface: renderer recovered", category: .surface)
            } else {
                Log.error(
                    "GhosttySurface: renderer unhealthy, pane may render black",
                    category: .surface)
            }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            // libghostty emits this whenever the viewport moves OR the buffer grows, so it
            // arrives on ordinary output too, not only on a scroll. The chrome reads it to say
            // where in the buffer scroll mode is sitting.
            let bar = action.action.scrollbar
            delegate?.surface(
                self,
                scrollPositionDidChange: TerminalScrollPosition(
                    total: Int(bar.total), offset: Int(bar.offset), viewport: Int(bar.len)))
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            // libghostty's own start-search and search-the-selection binds. Neither starts a
            // search: they ask the apprt to put a find bar up, seeded with the selection when
            // there is one. We never send them ourselves, but they are live keybinds in every
            // surface, so without this case they do nothing at all.
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

    /// React to a dynamic color a program set with OSC 4/10/11/12 (or reset with OSC 110–112).
    ///
    /// **This is not what makes the terminal honor them.** libghostty writes the color into
    /// `terminal.colors` before it sends this, and its renderer draws from there, so the grid
    /// already follows the program whether we handle this or not. The action exists so the app
    /// around the terminal can match — which is where the decision is (ZEN-23): the pane's own
    /// fill matches, and nothing else does. Every chrome role stays `Theme.current` (ZEN-91), so
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
        // A program that repaints its background to the other end of the range has changed what
        // this pane reports, so the answer follows the paint (see `syncColorScheme`).
        //
        // Deferred a turn, and that is load-bearing. This runs inside libghostty's own mailbox
        // drain, and the push ends in `ghostty_app_tick`, which drains the mailbox again. Called
        // inline, a second queued color change would be popped and completed *inside* this one,
        // so the nested handler would set `backgroundOverride` and notify the chrome with the
        // newer color, then this frame would unwind and notify with the older one, leaving the
        // pane's fill and frame painted a color the grid has already moved off. Deferring keeps
        // `handle` a leaf, which is what it was before this surface pushed anything back.
        DispatchQueue.main.async { [weak self] in self?.syncColorScheme() }
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

    /// Map a `MOUSE_OVER_LINK` payload onto the seam's hovered-link value. Pure, so the mapping
    /// is tested without a live surface. libghostty sends an empty string when the pointer leaves
    /// a link; the seam carries that as nil, matching `progressDidChange`'s "cleared" shape.
    /// Decode by `len` (not `strlen`) so an interior NUL can't truncate the URL, like `openURL`.
    static func hoveredLink(_ link: ghostty_action_mouse_over_link_s) -> String? {
        guard let ptr = link.url, link.len > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: ptr, count: Int(link.len)), as: UTF8.self)
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
