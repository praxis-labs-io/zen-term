import AppKit
import AppLog
import GhosttyKit

/// The process-global libghostty runtime.
///
/// libghostty has exactly one `ghostty_app_t` per process; every `GhosttySurface`
/// shares it. Created on first surface, with that surface's theme — configuration is
/// app-level in libghostty, and every zen-term pane shares one theme. The app is
/// event-driven: libghostty calls `wakeup_cb` from any thread when it has work, and we
/// hop to the main thread to `ghostty_app_tick`. Because there is only ever one
/// instance, the C callbacks reach it through `GhosttyApp.shared` rather than the
/// runtime `userdata` pointer, which sidesteps the init-ordering problem of handing
/// `self` to `ghostty_app_new` before `self` is fully constructed.
final class GhosttyApp {
    private static var _shared: GhosttyApp?

    /// The shared runtime, created on first call with the first surface's theme.
    /// Later calls return the existing instance — libghostty config is app-global, so a
    /// later surface's differing theme would not apply. No live bug today (all panes
    /// share one theme); per-surface theming via ghostty_surface_update_config is ZEN-27.
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
    // Retained for the app's (process) lifetime: libghostty keeps a reference to the
    // config passed to ghostty_app_new; freeing it would pull it out from under the app.
    // A `var`, not `let`: `updateConfig` swaps in a fresh config and frees this one, but
    // only AFTER the swap, so the app never sees a freed config.
    private var config: ghostty_config_t
    // Dedupe redundant app-global swaps: N per-surface `applyAppearance` callers for one
    // config change should trigger at most one real ghostty_app_update_config.
    private var lastConfigText: String?
    // NSApp activate/resign observers keeping libghostty's app-level focus in sync.
    private var focusObservers: [NSObjectProtocol] = []

    private init(theme: TerminalTheme?, behavior: TerminalBehavior?) {
        // Point the embedded lib at the resources staged from the pinned vendor/ghostty
        // build (shell integration, themes, terminfo) — libghostty resolves none of
        // these itself when embedded. Must be set before ghostty_init.
        Self.useBundledResources()

        // Global init once per process. argc/argv are libghostty's CLI entry (for
        // `ghostty +action` subcommands we never invoke) but the call is required.
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // The chrome's theme, translated to ghostty config text and loaded as the ONLY
        // config source — deliberately not ghostty_config_load_default_files, so a
        // user's ~/.config/ghostty can't skew zen-term's appearance or behavior.
        guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        if let generated = GhosttyConfigWriter.writeConfig(for: theme, behavior: behavior) {
            ghostty_config_load_file(cfg, generated)
        }
        ghostty_config_finalize(cfg)
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

    deinit { focusObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    func tick() { ghostty_app_tick(app) }

    /// Keep libghostty's app-level focus in sync with `NSApp`. It's set once at creation, but the
    /// app backgrounds/foregrounds afterward, and libghostty gates cursor-blink (and other
    /// focus-conditional behavior) on this flag — without these observers it believes the app is
    /// focused forever. Ghostty's own macOS app syncs on these same notifications.
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

    /// Re-load the app-global libghostty config from a fresh TerminalTheme/behavior and swap it
    /// live (re-themes every surface). Deduped by generated text so N per-surface callers trigger
    /// at most one real swap per change.
    func updateConfig(theme: TerminalTheme, behavior: TerminalBehavior) {
        let text = GhosttyConfigWriter.configText(for: theme, behavior: behavior)
        guard text != lastConfigText else { return }
        guard let cfg = ghostty_config_new() else { return }
        // If the generated config file can't be written, keep the CURRENT config rather than
        // pushing an effectively-default one that would drop the theme app-wide. Free the unused
        // cfg and leave `lastConfigText` untouched so a later reload with the same theme retries.
        guard let path = GhosttyConfigWriter.writeConfig(for: theme, behavior: behavior) else {
            ghostty_config_free(cfg)
            return
        }
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        ghostty_app_update_config(app, cfg)
        let old = config
        config = cfg
        ghostty_config_free(old)
        lastConfigText = text
        tick()
    }

    /// Apply a config to ONE surface, leaving the app-global config (and every other surface)
    /// untouched. `GhosttySurface` uses this for the shader settle-burst (ZEN-237).
    ///
    /// The config is freed on the way out, unlike the app-global one: `ghostty_app_update_config`
    /// keeps the pointer it's handed, while the surface path derives its own copy
    /// (`Surface.updateConfig` → `DerivedConfig.init`) and never retains ours.
    func updateSurfaceConfig(
        _ surfacePtr: ghostty_surface_t, theme: TerminalTheme?, behavior: TerminalBehavior,
        shaderAnimation: GhosttyConfigWriter.ShaderAnimation
    ) {
        guard let cfg = ghostty_config_new() else { return }
        guard
            let path = GhosttyConfigWriter.writeConfig(
                for: theme, behavior: behavior, shaderAnimation: shaderAnimation,
                variant: "surface")
        else {
            // Same reasoning as updateConfig: a failed write means keep what the surface has
            // rather than push an effectively-default config that would drop its theme.
            ghostty_config_free(cfg)
            return
        }
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        ghostty_surface_update_config(surfacePtr, cfg)
        ghostty_config_free(cfg)
        tick()
    }

    /// Point `GHOSTTY_RESOURCES_DIR` at the resources bin/build-ghosttykit staged into
    /// TerminalKit's bundle, always overriding any inherited value. The env var points
    /// at the `ghostty/` dir; libghostty derives `TERMINFO` from its *sibling*
    /// `terminfo/` — the same layout as Ghostty.app's `Resources/{ghostty,terminfo}`
    /// pair. We override rather than defer to an inherited value because launching
    /// zen-term from inside Ghostty would otherwise inherit that Ghostty's
    /// `GHOSTTY_RESOURCES_DIR` — a possibly different version than our pinned libghostty,
    /// silently mismatching shell-integration scripts and terminfo.
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

    /// Route a surface-targeted action (title / pwd / bell / child-exit) to its
    /// `GhosttySurface`. App-level actions are ignored — the chrome owns app-level
    /// behavior (tabs, splits, palette), not the terminal backend. The surface is
    /// recovered from the `userdata` we set on its config at creation.
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

    /// libghostty asks us to confirm a clipboard read (its `clipboard-read = ask` path).
    /// We already allow reads outright in `readClipboard`, so auto-confirm with the
    /// content libghostty hands us — a no-op here leaves the requesting program hanging.
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

    /// libghostty wants the surface closed (shell exited, or `exit`). Report it up the
    /// seam so the chrome can tear down the pane.
    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
        guard let surface = surface(from: userdata) else { return }
        DispatchQueue.main.async { surface.reportClose() }
    }
}
