import AppKit
import AppLog
import GhosttyKit

/// The process-global libghostty runtime. There is exactly one `ghostty_app_t` per process and
/// every `GhosttySurface` shares it, created on the first surface with that surface's theme.
///
/// Event-driven: libghostty calls `wakeup_cb` from any thread when it has work, and we hop to the
/// main thread to `ghostty_app_tick`. The C callbacks reach the instance through
/// `GhosttyApp.shared` rather than the runtime `userdata` pointer, which sidesteps handing `self`
/// to `ghostty_app_new` before `self` is fully constructed.
final class GhosttyApp {
    private static var _shared: GhosttyApp?

    /// The shared runtime, created on first call with the first surface's theme. Later calls
    /// return the existing instance, so a later surface's differing theme would not apply through
    /// this path. `updateSurfaceConfig` is how one surface gets its own config.
    static func shared(theme: TerminalTheme?, behavior: TerminalBehavior?) -> GhosttyApp {
        if let existing = _shared { return existing }
        let created = GhosttyApp(theme: theme, behavior: behavior)
        _shared = created
        return created
    }

    /// The already-created runtime — for the C callbacks and the event-loop pump,
    /// which can only fire after the first surface (and therefore the app) exists.
    static var shared: GhosttyApp {
        guard let shared = _shared else {
            fatalError("GhosttyApp accessed before the first GhosttySurface created it")
        }
        return shared
    }

    let app: ghostty_app_t
    // Retained for the process lifetime: libghostty keeps a reference to the config passed to
    // ghostty_app_new. A `var` because `updateConfig` swaps in a fresh one and frees this, but
    // only AFTER the swap, so the app never sees a freed config.
    private var config: ghostty_config_t
    // Dedupe redundant app-global swaps: N per-surface `applyAppearance` callers for one
    // config change should trigger at most one real ghostty_app_update_config.
    private var lastConfigText: String?
    /// Finalized per-surface configs, keyed by the config text that produced them.
    ///
    /// libghostty takes configuration only from files, so building one is a synchronous write,
    /// read and parse on the main thread. The shader settle path makes that hot: switching panes
    /// stands one surface down and restores another, three round-trips per switch before this.
    ///
    /// Safe to share one config across surfaces and calls, because `ghostty_surface_update_config`
    /// derives its own copy and never retains the pointer we pass. Freed whenever the app-global
    /// config changes, since every cached shape derives from the theme that just moved.
    private var surfaceConfigCache: [String: ghostty_config_t] = [:]
    // NSApp activate/resign observers keeping libghostty's app-level focus in sync.
    private var focusObservers: [NSObjectProtocol] = []

    private init(theme: TerminalTheme?, behavior: TerminalBehavior?) {
        // libghostty resolves none of these itself when embedded. Must be set before
        // ghostty_init.
        Self.useBundledResources()

        // Global init once per process. argc/argv are libghostty's CLI entry (for
        // `ghostty +action` subcommands we never invoke) but the call is required.
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // The ONLY config source, deliberately not ghostty_config_load_default_files, so a user's
        // ~/.config/ghostty can't skew zen-term's appearance or behavior.
        guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        if let generated = GhosttyConfigWriter.writeConfig(for: theme, behavior: behavior) {
            ghostty_config_load_file(cfg, generated)
        }
        ghostty_config_finalize(cfg)
        Self.logDiagnostics(of: cfg, context: "init")
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyApp.wakeup() },
            action_cb: { app, target, action in GhosttyApp.action(app, target, action) },
            read_clipboard_cb: { ud, loc, state in GhosttyApp.readClipboard(ud, loc, state) },
            confirm_read_clipboard_cb: { ud, str, state, _ in
                GhosttyApp.confirmReadClipboard(ud, str, state)
            },
            write_clipboard_cb: { ud, _, content, len, _ in GhosttyApp.writeClipboard(ud, content, len) },
            close_surface_cb: { ud, alive in GhosttyApp.closeSurface(ud, alive) }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            fatalError("ghostty_app_new failed")
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        observeAppFocus()
    }

    deinit {
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        clearSurfaceConfigCache()
    }

    func tick() { ghostty_app_tick(app) }

    /// Keep libghostty's app-level focus in sync with `NSApp`. It is set once at creation and
    /// gates cursor-blink and other focus-conditional behavior, so without these observers
    /// libghostty believes the app is focused forever.
    private func observeAppFocus() {
        let center = NotificationCenter.default
        let apply: (Bool) -> Void = { [weak self] focused in
            guard let self else { return }
            ghostty_app_set_focus(self.app, focused)
            self.tick()  // pump so the focus change takes effect promptly (blink, etc.)
        }
        focusObservers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in apply(true) },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { _ in apply(false) },
        ]
    }

    /// Re-load the app-global config from a fresh theme and behavior and swap it live, re-theming
    /// every surface. Deduped by generated text, so N callers trigger at most one real swap.
    func updateConfig(theme: TerminalTheme, behavior: TerminalBehavior) {
        let text = GhosttyConfigWriter.configText(for: theme, behavior: behavior)
        guard text != lastConfigText else { return }
        guard let cfg = ghostty_config_new() else { return }
        // Keep the CURRENT config rather than pushing an effectively-default one that would drop
        // the theme app-wide. `lastConfigText` is left untouched so the same theme retries later.
        guard let path = GhosttyConfigWriter.writeConfig(for: theme, behavior: behavior) else {
            ghostty_config_free(cfg)
            return
        }
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        Self.logDiagnostics(of: cfg, context: "updateConfig")
        ghostty_app_update_config(app, cfg)
        let old = config
        config = cfg
        ghostty_config_free(old)
        lastConfigText = text
        clearSurfaceConfigCache()
        tick()
    }

    /// Apply a config to ONE surface, leaving the app-global config and every other surface
    /// untouched.
    ///
    /// Returns whether a config actually reached the surface. Callers that depend on the push
    /// having landed have to check: the failure paths below leave the surface on its previous
    /// config, and anything riding along with the push does not take effect either.
    ///
    /// `fontSize` should be the size the surface is actually running, because a config carrying
    /// the theme's size resets any surface libghostty has not marked `font_size_adjusted`.
    @discardableResult
    func updateSurfaceConfig(
        _ surfacePtr: ghostty_surface_t, theme: TerminalTheme?, behavior: TerminalBehavior,
        shaderAnimation: GhosttyConfigWriter.ShaderAnimation, fontSize: CGFloat? = nil
    ) -> Bool {
        let text = GhosttyConfigWriter.configText(
            for: theme, behavior: behavior, shaderAnimation: shaderAnimation, fontSize: fontSize)
        if let cached = surfaceConfigCache[text] {
            ghostty_surface_update_config(surfacePtr, cached)
            tick()
            return true
        }
        guard let cfg = ghostty_config_new() else { return false }
        guard
            let path = GhosttyConfigWriter.writeConfig(
                for: theme, behavior: behavior, shaderAnimation: shaderAnimation,
                variant: "surface", fontSize: fontSize)
        else {
            // Same reasoning as updateConfig: a failed write means keep what the surface has
            // rather than push an effectively-default config that would drop its theme.
            ghostty_config_free(cfg)
            return false
        }
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        Self.logDiagnostics(of: cfg, context: "updateSurfaceConfig")
        // Retained, not freed: it goes in the cache for every later call with this same shape.
        surfaceConfigCache[text] = cfg
        ghostty_surface_update_config(surfacePtr, cfg)
        tick()
        return true
    }

    /// Every diagnostic libghostty attached to a finalized config. The config is entirely
    /// generated, so a diagnostic never means user error: `GhosttyConfigWriter` emitted something
    /// this pin does not understand, and that setting is silently not applying.
    static func diagnostics(of cfg: ghostty_config_t) -> [String] {
        (0..<ghostty_config_diagnostics_count(cfg)).compactMap { index in
            ghostty_config_get_diagnostic(cfg, index).message.map { String(cString: $0) }
        }
    }

    private static func logDiagnostics(of cfg: ghostty_config_t, context: String) {
        for message in diagnostics(of: cfg) {
            Log.error("GhosttyApp: config diagnostic (\(context)): \(message)", category: .config)
        }
    }

    /// Free every cached per-surface config. Called when the app-global config moves, because each
    /// cached shape was derived from the theme and behavior that just changed.
    private func clearSurfaceConfigCache() {
        surfaceConfigCache.values.forEach { ghostty_config_free($0) }
        surfaceConfigCache.removeAll()
    }

    /// Point `GHOSTTY_RESOURCES_DIR` at the resources staged into TerminalKit's bundle. The var
    /// points at the `ghostty/` dir and libghostty derives `TERMINFO` from its *sibling*.
    ///
    /// Always overrides an inherited value: launching zen-term from inside Ghostty would otherwise
    /// inherit that Ghostty's resources, silently mismatching shell integration and terminfo
    /// against our pinned libghostty.
    private static func useBundledResources() {
        guard
            let dir = TerminalKitResources.bundle.resourceURL?
                .appendingPathComponent("ghostty-resources/ghostty").path,
            FileManager.default.fileExists(atPath: dir)
        else {
            Log.warning(
                "GhosttyApp: staged ghostty resources missing — shell integration and "
                    + "terminfo degraded. Re-run bin/build-ghosttykit.", category: .surface)
            return
        }
        setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
    }

    // MARK: - C callbacks

    /// libghostty has work to do. Called from any thread, so hop to main and tick.
    private static func wakeup() {
        DispatchQueue.main.async { GhosttyApp.shared.tick() }
    }

    /// Route a surface-targeted action to its `GhosttySurface`, recovered from the `userdata` set
    /// on its config at creation. App-level actions are ignored: the chrome owns app-level
    /// behavior, not the terminal backend.
    private static func action(
        _ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surfacePtr = target.target.surface,
            let ud = ghostty_surface_userdata(surfacePtr)
        else { return false }
        let surface = Unmanaged<GhosttySurface>.fromOpaque(ud).takeUnretainedValue()
        return surface.handle(action)
    }

    private static func surface(from userdata: UnsafeMutableRawPointer?) -> GhosttySurface? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurface>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// A terminal app asked to read the clipboard (e.g. a paste keybind). Hand back the
    /// system pasteboard's string, or false so a performable paste falls through.
    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let surface = surface(from: userdata), let ptr = surface.surfacePtr else { return false }
        guard let str = NSPasteboard.general.string(forType: .string) else { return false }
        str.withCString { ghostty_surface_complete_clipboard_request(ptr, $0, state, false) }
        return true
    }

    /// libghostty asks us to confirm a clipboard read. We allow reads outright in `readClipboard`,
    /// so auto-confirm: a no-op here leaves the requesting program hanging.
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ string: UnsafePointer<CChar>?,
        _ state: UnsafeMutableRawPointer?
    ) {
        guard let surface = surface(from: userdata), let ptr = surface.surfacePtr, let string
        else { return }
        ghostty_surface_complete_clipboard_request(ptr, string, state, true)
    }

    /// A terminal app asked to write the clipboard (in-terminal copy / OSC 52). Mirror
    /// the first text/plain entry to the system pasteboard.
    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ len: Int
    ) {
        guard surface(from: userdata) != nil, let content, len > 0 else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data
            else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
            return
        }
    }

    /// libghostty wants the surface closed. Deliberately does nothing, and is registered only so
    /// libghostty doesn't log that the embedder can't close a surface on every close.
    ///
    /// Safe because the child-exit path is the only one that reaches us, and a child exit has
    /// already gone to `surfaceDidExit`, where the chrome tears the pane down. The other callers
    /// of `Surface.close` never fire because the chrome owns close: ⌘W is taken by
    /// `KeyInterceptor` before libghostty sees it, and nothing calls
    /// `ghostty_surface_request_close`. **If either changes, this needs a real implementation.**
    ///
    /// `processAlive` is libghostty's `needsConfirmQuit()`, not "something is still running here".
    /// Confirmation is the chrome's and what survives a close is the reaper's, so neither wants it.
    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
}
