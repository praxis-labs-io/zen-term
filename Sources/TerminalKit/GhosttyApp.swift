import AppKit
import GhosttyKit

/// The process-global libghostty runtime (ZEN-40 spike).
///
/// libghostty has exactly one `ghostty_app_t` per process; every `GhosttySurface`
/// shares it. Created lazily on first surface. The app is event-driven: libghostty
/// calls `wakeup_cb` from any thread when it has work, and we hop to the main thread
/// to `ghostty_app_tick`. Because there is only ever one instance, the C callbacks
/// reach it through `GhosttyApp.shared` rather than the runtime `userdata` pointer,
/// which sidesteps the init-ordering problem of handing `self` to `ghostty_app_new`
/// before `self` is fully constructed.
final class GhosttyApp {
    static let shared = GhosttyApp()

    let app: ghostty_app_t
    private let config: ghostty_config_t

    private init() {
        // Global init once per process. argc/argv are libghostty's CLI entry (for
        // `ghostty +action` subcommands we never invoke) but the call is required.
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // Defaults plus the user's own ghostty config files (font, theme, etc.) if
        // present. App-level keybinds we don't handle surface as ignored actions.
        guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in GhosttyApp.wakeup() },
            action_cb: { app, target, action in GhosttyApp.action(app, target, action) },
            read_clipboard_cb: { ud, loc, state in GhosttyApp.readClipboard(ud, loc, state) },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { ud, _, content, len, _ in GhosttyApp.writeClipboard(ud, content, len) },
            close_surface_cb: { ud, alive in GhosttyApp.closeSurface(ud, alive) }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            fatalError("ghostty_app_new failed")
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    func tick() { ghostty_app_tick(app) }

    // MARK: - C callbacks

    /// libghostty has work to do. Called from any thread, so hop to main and tick.
    private static func wakeup() {
        DispatchQueue.main.async { GhosttyApp.shared.tick() }
    }

    /// Route a surface-targeted action (title / pwd / bell / child-exit) to its
    /// `GhosttySurface`. App-level actions are ignored for the spike. The surface is
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
