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
    // Retained for the app's (process) lifetime: libghostty keeps a reference to the
    // config passed to ghostty_app_new; freeing it would pull it out from under the app.
    private let config: ghostty_config_t

    private init() {
        // Point the embedded lib at the resources staged from the pinned vendor/ghostty
        // build (shell integration, themes, terminfo) — libghostty resolves none of
        // these itself when embedded. Must be set before ghostty_init.
        Self.useBundledResources()

        // Global init once per process. argc/argv are libghostty's CLI entry (for
        // `ghostty +action` subcommands we never invoke) but the call is required.
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        // The spike config (Rosé Pine Moon, JetBrainsMono) loaded on top of any real
        // user config. Kept in-repo so it never touches ~/.config/ghostty.
        guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        ghostty_config_load_default_files(cfg)
        if let spikeConfig = Self.spikeConfigPath {
            ghostty_config_load_file(cfg, spikeConfig)
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
    }

    func tick() { ghostty_app_tick(app) }

    /// Absolute path to the in-repo spike config, resolved from this source file's
    /// location (`#filePath`) — the spike runs on the same machine it's built on, so
    /// this is robust regardless of the launch working directory. Nil if missing.
    private static var spikeConfigPath: String? {
        let root = URL(fileURLWithPath: #filePath)  // Sources/TerminalKit/GhosttyApp.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("config/ghostty/config").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Set `GHOSTTY_RESOURCES_DIR` to the resources bin/build-ghosttykit staged into
    /// TerminalKit's bundle, unless the user already set it. The env var points at the
    /// `ghostty/` dir; libghostty derives `TERMINFO` from its *sibling* `terminfo/` —
    /// the same layout as Ghostty.app's `Resources/{ghostty,terminfo}` pair.
    private static func useBundledResources() {
        guard ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil else { return }
        guard
            let dir = Bundle.module.resourceURL?
                .appendingPathComponent("ghostty-resources/ghostty").path,
            FileManager.default.fileExists(atPath: dir)
        else {
            NSLog(
                "GhosttyApp: staged ghostty resources missing — shell integration and "
                    + "terminfo degraded. Re-run bin/build-ghosttykit.")
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
