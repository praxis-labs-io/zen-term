import AppKit
import GhosttyKit

/// libghostty-backed terminal surface — the default backend (ZEN-45).
///
/// The counterpart to `SwiftTermSurface` behind the same `TerminalSurface` seam, so
/// the chrome is identical either way. Unlike SwiftTerm's drop-in `NSView`, libghostty
/// renders into a Metal layer it attaches to a host view we own, and the host must
/// forward every input (key / mouse / focus / size / scale) and pump the shared app's
/// event loop. IME/dead-key composition is not wired yet (no `NSTextInputClient`);
/// tracked in ZEN-67.
public final class GhosttySurface: NSObject, TerminalSurface {
    private let hostView = GhosttyHostView()
    var surfacePtr: ghostty_surface_t?
    private var lastTitle = ""
    private var lastCwd: URL?

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
    /// True process-group parity with the SwiftTerm ProcessProbe is a follow-up.
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
        // spawns lazygit/floats as `-c "cmd; exec zsh -l -i"`, so this is load-bearing.
        // `command == nil` lets libghostty launch the user's login shell itself.
        let command: String? = config.command.map { cmd in
            ([cmd] + config.args).map(Self.shellWordQuote).joined(separator: " ")
        }

        surfacePtr = Self.withConfigStrings(
            &cfg,
            workingDirectory: config.workingDirectory?.path,
            command: command,
            environment: config.environment
        ) { ghostty_surface_new(GhosttyApp.shared(theme: config.theme).app, &$0) }

        hostView.surfacePtr = surfacePtr

        // libghostty just made hostView layer-hosting (its Metal layer is now
        // hostView.layer). The host window is transparent for the vibrancy backdrop, so
        // by default the compositor blends this layer against that backdrop every frame —
        // which tears under heavy TUI redraws and flashes the (light) backdrop through any
        // redraw gap. Mark the layer opaque over the terminal background so it composites
        // as a solid surface and gaps show the terminal bg, not the window behind it.
        if let layer = hostView.layer {
            layer.isOpaque = true
            layer.backgroundColor = (config.theme?.background.nsColor ?? .black).cgColor
        }

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

    public func focus() { hostView.window?.makeFirstResponder(hostView) }

    public func terminate() {
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
        if let surfacePtr {
            ghostty_surface_free(surfacePtr)
            hostView.surfacePtr = nil
        }
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
        default:
            return false
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
