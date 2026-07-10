import AppKit
import SwiftTerm

/// SwiftTerm-backed terminal surface. The only type in TerminalKit that touches
/// SwiftTerm. Bell is forwarded via the `ProbeTerminalView` subclass override
/// (Task 8 spike); notify / progress could not be overridden from a subclass
/// (see `ProbeTerminalView`'s doc comment) and are not wired.
public final class SwiftTermSurface: NSObject, TerminalSurface {
    private let term = ProbeTerminalView(frame: .zero)
    private var lastTitle = ""

    /// A local NSEvent monitor for two behaviors SwiftTerm doesn't give us and won't let
    /// us add by subclassing (it seals `keyDown`/`mouseDown` as `public`, not `open`):
    /// Shift+Enter → LF (soft newline), and focus-on-content-click (SwiftTerm's mouseDown
    /// neither becomes first responder nor bubbles). Each surface installs one; every
    /// handler no-ops unless the event targets *this* surface, so they don't interfere.
    private var eventMonitor: Any?

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { term }
    public var title: String { lastTitle }
    public var isFocused: Bool { term.window?.firstResponder === term }

    /// The shell's live cwd, read from the child process via the kernel
    /// (`proc_pidinfo` / `PROC_PIDVNODEPATHINFO`). This is how Terminal.app and iTerm
    /// track cwd without shell integration — no OSC 7 required. Nil before the
    /// process starts or if the lookup fails.
    public var currentDirectory: URL? {
        let pid = term.process?.shellPid ?? 0
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard read == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: Array(bytes))
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Whether a foreground command is running in the shell (an idle prompt or a backgrounded
    /// job reads as not busy — the pty's foreground process group is the shell itself).
    public var isBusy: Bool {
        guard let process = term.process else { return false }
        return ProcessProbe.hasForegroundJob(masterFd: process.childfd, shellPid: process.shellPid)
    }

    public override init() {
        super.init()
        term.processDelegate = self
        term.onBell = { [weak self] in
            guard let self else { return }
            self.delegate?.surfaceDidRingBell(self)
        }
        // Intercept OSC 777 `notify;<title>;<body>` — the desktop-notification convention an
        // agent (e.g. Claude Code's Ghostty mode) emits when it wants the user. A registered
        // handler takes priority over SwiftTerm's built-in (a Mac no-op), so this is the one
        // place the payload is reachable. The sequence's trailing BEL is its terminator, not a
        // bell ring, so this never overlaps the `onBell` path.
        term.getTerminal().registerOscHandler(code: 777) { [weak self] data in
            self?.handleNotifyOSC(data)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .mouseMoved]) {
            [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown: return self.handleShiftEnter(event)
            case .leftMouseDown: self.reportFocusIfClicked(event); return event
            case .mouseMoved: return self.suppressHoverMotion(event)
            default: return event
            }
        }
    }

    /// Map Shift+Enter to a line feed so multiline-aware CLIs treat it as a soft newline
    /// while plain Enter (carriage return) still submits — the CR-submits / LF-inserts
    /// convention, and exactly what `claude /terminal-setup` writes for the terminals it
    /// configures. Only the focused surface acts.
    private func handleShiftEnter(_ event: NSEvent) -> NSEvent? {
        guard term.window?.firstResponder === term,
            event.keyCode == 36,  // kVK_Return (main Return)
            event.modifierFlags.contains(.shift)
        else { return event }
        term.send([0x0A])  // LF
        return nil
    }

    /// Whether the event's location hit-tests into this surface's own content — and not
    /// a view covering it (e.g. an overlay this surface sits behind). Shared by
    /// focus-on-click and hover-motion suppression so both agree on "is this my view."
    private func hitTestsIntoSurface(_ event: NSEvent) -> Bool {
        guard event.window === term.window,
            let hit = term.window?.contentView?.hitTest(event.locationInWindow)
        else { return false }
        return hit === term || hit.isDescendant(of: term)
    }

    /// Report a focus intent when a click lands in this surface's content. SwiftTerm's
    /// `mouseDown` consumes the click for selection without becoming first responder or
    /// bubbling, so clicks never reached the chrome's focus routing. We only observe
    /// (never swallow the event, so selection still works) and only when the click
    /// hit-tests into this surface's view — never a covered one behind an overlay.
    private func reportFocusIfClicked(_ event: NSEvent) {
        guard hitTestsIntoSurface(event) else { return }
        delegate?.surfaceWantsFocus(self)
    }

    /// Drop no-button hover motion over this surface. Under any-event mouse tracking
    /// (DEC 1003, which turborepo's dev TUI enables) SwiftTerm encodes a no-button
    /// motion as `ESC[<32;x;ym`: the low two bits (0) read as the LEFT button and the
    /// trailing `m` as a release, so a mouse-tracking app decodes plain hover as a
    /// left-button drag and begins selecting text under the cursor — the phantom
    /// highlight in turbo's log pane. Correct terminals emit no-button motion the app
    /// ignores, so nothing highlights. SwiftTerm's `mouseMoved` is sealed `public` (not
    /// `open`), so we can't fix its encoder from a subclass — instead we drop the event
    /// before it reaches the view. Only pure hover is dropped: real drags arrive as
    /// `.leftMouseDragged` and still report correctly. This suppresses rather than
    /// re-encodes, so a TUI that legitimately drives hover UI over DEC 1003 loses it too
    /// (tracked as a follow-up to emit correct no-button motion instead). Scoped by
    /// hit-test so it never swallows events destined for another view.
    private func suppressHoverMotion(_ event: NSEvent) -> NSEvent? {
        hitTestsIntoSurface(event) ? nil : event
    }

    public func start(_ config: TerminalSurfaceConfig) {
        if let theme = config.theme { applyTheme(theme) }
        if let behavior = config.behavior { applyBehavior(behavior) }
        let base = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        // Present as Ghostty so terminal-aware tools that auto-detect the host — notably
        // Claude Code's "auto" notification mode — pick a channel we actually handle: OSC 777
        // desktop notifications (intercepted in `init`). `TERM` stays `xterm-256color`, so
        // terminfo-based rendering is unchanged; only the app-level identity advertises Ghostty.
        var overrides = config.environment
        // Only when the caller hasn't set its own identity (an explicit override still wins).
        // The version is a current Ghostty release — high enough to clear an agent's minimum-
        // version gate for OSC 777, without implying capabilities the SwiftTerm backend lacks.
        if overrides["TERM_PROGRAM"] == nil {
            overrides["TERM_PROGRAM"] = "ghostty"
            overrides["TERM_PROGRAM_VERSION"] = "1.1.3"
        }
        let environment = EnvBuilder.merged(base: base, overrides: overrides)
        let isDefaultShell = config.command == nil
        let shell =
            config.command
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"

        // When launching the user's DEFAULT shell, make it a LOGIN shell by prefixing
        // argv[0] with "-". Without this the shell skips its login files (~/.zprofile,
        // /etc/zprofile), so Homebrew's `brew shellenv` never runs and the user gets a
        // bare PATH with no HOMEBREW_PREFIX — SwiftTerm's base env also omits PATH by
        // design. A login shell rebuilds PATH/env from the user's real config, matching
        // Terminal.app. An explicitly requested command (e.g. a future `lazygit`) is
        // launched as-is — argv[0] rewriting only makes sense for a shell.
        let execName = isDefaultShell ? "-" + URL(fileURLWithPath: shell).lastPathComponent : nil

        term.startProcess(
            executable: shell,
            args: config.args,
            environment: environment,
            execName: execName,
            currentDirectory: config.workingDirectory?.path
        )

        // Remove SwiftTerm's built-in scroller entirely: terminals don't need a
        // persistent scroll handle, and it visually doubles up with TUIs (e.g. nvim)
        // that draw their own. It's installed at init (setup → setupScroller), so it
        // exists here. Fully detach it — updateScroller() keeps operating on the
        // (now off-screen) instance harmlessly.
        for case let scroller as NSScroller in term.subviews {
            scroller.removeFromSuperview()
        }
    }

    /// Maps a chrome-supplied `TerminalTheme` onto the SwiftTerm view: font, the 16
    /// ANSI colors, and the default fg/bg, cursor, and selection colors.
    private func applyTheme(_ theme: TerminalTheme) {
        if let font = NSFont(name: theme.fontName, size: theme.fontSize) {
            term.font = font
        }
        if theme.ansi.count == 16 {
            // SwiftTerm.Color channels are 16-bit; scale 8-bit components by 257 (0xFF→0xFFFF).
            term.installColors(
                theme.ansi.map {
                    SwiftTerm.Color(
                        red: UInt16($0.red) * 257, green: UInt16($0.green) * 257, blue: UInt16($0.blue) * 257)
                })
        }
        term.nativeBackgroundColor = theme.background.nsColor
        term.nativeForegroundColor = theme.foreground.nsColor
        term.caretColor = theme.cursor.nsColor
        term.selectedTextBackgroundColor = theme.selectionBackground.nsColor
    }

    /// Applies the subset of `TerminalBehavior` SwiftTerm can honor: Option-as-Meta and the
    /// cursor style/blink. The scroll multiplier has no hook here — SwiftTerm owns its own
    /// scroll handling — so it's intentionally ignored (the ghostty backend honors it).
    private func applyBehavior(_ behavior: TerminalBehavior) {
        term.optionAsMetaKey = behavior.optionAsAlt
        let style: SwiftTerm.CursorStyle
        switch (behavior.cursorStyle, behavior.cursorBlink) {
        case (.block, true): style = .blinkBlock
        case (.block, false): style = .steadyBlock
        case (.bar, true): style = .blinkBar
        case (.bar, false): style = .steadyBar
        case (.underline, true): style = .blinkUnderline
        case (.underline, false): style = .steadyUnderline
        }
        term.getTerminal().setCursorStyle(style)
    }

    /// Parse an OSC 777 `notify;<title>;<body>` payload and surface it as a
    /// `TerminalNotification`. The body may itself contain `;`, so everything past the title
    /// is rejoined. Non-`notify` OSC 777 subcommands are ignored.
    private func handleNotifyOSC(_ data: ArraySlice<UInt8>) {
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: ";")
        guard parts.first == "notify", parts.count >= 2 else { return }
        let title = parts[1]
        let body = parts.count >= 3 ? parts[2...].joined(separator: ";") : ""
        delegate?.surface(self, didPostNotification: TerminalNotification(title: title, body: body))
    }

    public func focus() { term.window?.makeFirstResponder(term) }
    public func terminate() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        term.terminate()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
    public func paste(_ text: String) { term.send(txt: text) }
    public func copySelection() -> String? { term.getSelection() }
    public func scrollToBottom() { term.scroll(toPosition: 1) }
}

extension SwiftTermSurface: LocalProcessTerminalViewDelegate {
    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        lastTitle = title
        delegate?.surface(self, titleDidChange: title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = OSC7.fileURL(from: directory) else { return }
        delegate?.surface(self, cwdDidChange: url)
    }

    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        delegate?.surfaceDidExit(self, code: exitCode)
    }
}
