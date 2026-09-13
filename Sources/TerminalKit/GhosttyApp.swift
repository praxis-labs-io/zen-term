import AppKit
import AppLog
import GhosttyKit

// One `ghostty_app_t` per process. C callbacks use `shared`, since `userdata` would need `self` before init.
final class GhosttyApp {
    private static var _shared: GhosttyApp?

    // Later surfaces' themes do not apply here; `updateSurfaceConfig` gives one surface its own config.
    static func shared(theme: TerminalTheme?, behavior: TerminalBehavior?) -> GhosttyApp {
        if let existing = _shared { return existing }
        let created = GhosttyApp(theme: theme, behavior: behavior)
        _shared = created
        return created
    }

    static var shared: GhosttyApp {
        guard let shared = _shared else {
            fatalError("GhosttyApp accessed before the first GhosttySurface created it")
        }
        return shared
    }

    let app: ghostty_app_t
    // libghostty keeps a reference to the config it was created with, so it is freed only after a swap.
    private var config: ghostty_config_t
    private var lastConfigText: String?
    // Building a config is a synchronous file round-trip; `ghostty_surface_update_config` copies, so sharing is safe.
    private var surfaceConfigCache: [String: ghostty_config_t] = [:]
    private var focusObservers: [NSObjectProtocol] = []

    // Never loads default config files, so a user's ~/.config/ghostty cannot skew zen-term.
    private init(theme: TerminalTheme?, behavior: TerminalBehavior?) {
        Self.useBundledResources()

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

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

    // libghostty's app focus gates cursor blink and is otherwise set only once at creation.
    private func observeAppFocus() {
        let center = NotificationCenter.default
        let apply: (Bool) -> Void = { [weak self] focused in
            guard let self else { return }
            ghostty_app_set_focus(self.app, focused)
            self.tick()
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

    func updateConfig(theme: TerminalTheme, behavior: TerminalBehavior) {
        let text = GhosttyConfigWriter.configText(for: theme, behavior: behavior)
        guard text != lastConfigText else { return }
        guard let cfg = ghostty_config_new() else { return }
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

    // Returns false when the push failed and the surface kept its previous config.
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
            ghostty_config_free(cfg)
            return false
        }
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        Self.logDiagnostics(of: cfg, context: "updateSurfaceConfig")
        surfaceConfigCache[text] = cfg
        ghostty_surface_update_config(surfacePtr, cfg)
        tick()
        return true
    }

    // The config is fully generated, so any diagnostic means a setting this ghostty pin silently ignores.
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

    private func clearSurfaceConfigCache() {
        surfaceConfigCache.values.forEach { ghostty_config_free($0) }
        surfaceConfigCache.removeAll()
    }

    // Always overrides an inherited `GHOSTTY_RESOURCES_DIR`, which launching from Ghostty would mismatch.
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

    private static func wakeup() {
        DispatchQueue.main.async { GhosttyApp.shared.tick() }
    }

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

    // Auto-confirms, since reads are allowed outright; leaving it unanswered hangs the program.
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ string: UnsafePointer<CChar>?,
        _ state: UnsafeMutableRawPointer?
    ) {
        guard let surface = surface(from: userdata), let ptr = surface.surfacePtr, let string
        else { return }
        ghostty_surface_complete_clipboard_request(ptr, string, state, true)
    }

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

    // Only child exit reaches this, and the chrome already closes the pane then. Registered to silence libghostty.
    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
}
