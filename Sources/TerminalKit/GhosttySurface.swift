import AppKit
import GhosttyKit

/// libghostty-backed terminal surface (ZEN-40 spike).
///
/// The counterpart to `SwiftTermSurface` behind the same `TerminalSurface` seam, so
/// the chrome is identical either way. Unlike SwiftTerm's drop-in `NSView`, libghostty
/// renders into a Metal layer it attaches to a host view we own, and the host must
/// forward every input (key / mouse / focus / size / scale) and pump the shared app's
/// event loop. This is a spike: basic typing, mouse, scroll, resize, title/cwd/bell,
/// and clipboard work; IME/dead-key composition and full keybind coverage are out of
/// scope (see ZEN-40).
public final class GhosttySurface: NSObject, TerminalSurface {
    private let hostView = GhosttyHostView()
    var surfacePtr: ghostty_surface_t?
    private var lastTitle = ""
    private var lastPwd: URL?

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { hostView }
    public var title: String { lastTitle }
    public var isFocused: Bool { hostView.window?.firstResponder === hostView }
    public var currentDirectory: URL? { lastPwd }

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

        // libghostty's `command` is a single shell-parsed string, not argv; join the
        // chrome's command + args. `command == nil` lets libghostty launch the user's
        // login shell itself (it handles login/PATH natively — no argv[0] rewrite needed).
        let command: String? = config.command.map { ([$0] + config.args).joined(separator: " ") }

        surfacePtr = Self.withConfigStrings(
            &cfg,
            workingDirectory: config.workingDirectory?.path,
            command: command,
            environment: config.environment
        ) { ghostty_surface_new(GhosttyApp.shared.app, &$0) }

        hostView.surfacePtr = surfacePtr
        hostView.syncSizeAndScale()
        GhosttyApp.shared.tick()
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

    public func focus() { hostView.window?.makeFirstResponder(hostView) }

    public func terminate() {
        guard let surfacePtr else { return }
        ghostty_surface_free(surfacePtr)
        self.surfacePtr = nil
        hostView.surfacePtr = nil
    }

    public func paste(_ text: String) {
        guard let surfacePtr else { return }
        text.withCString { ghostty_surface_text(surfacePtr, $0, UInt(strlen($0))) }
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
            lastPwd = url
            delegate?.surface(self, cwdDidChange: url)
            return true
        case GHOSTTY_ACTION_RING_BELL:
            delegate?.surfaceDidRingBell(self)
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let code = Int32(action.action.child_exited.exit_code)
            delegate?.surfaceDidExit(self, code: code)
            return true
        default:
            return false
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
