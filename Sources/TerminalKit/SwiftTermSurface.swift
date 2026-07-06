import AppKit
import SwiftTerm

/// SwiftTerm-backed terminal surface. The only type in TerminalKit that touches
/// SwiftTerm. Bell is forwarded via the `ProbeTerminalView` subclass override
/// (Task 8 spike); notify / progress could not be overridden from a subclass
/// (see `ProbeTerminalView`'s doc comment) and are not wired.
public final class SwiftTermSurface: NSObject, TerminalSurface {
    private let term = ProbeTerminalView(frame: .zero)
    private var lastTitle = ""

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { term }
    public var title: String { lastTitle }
    public var isFocused: Bool { term.window?.firstResponder === term }

    public override init() {
        super.init()
        term.processDelegate = self
        term.onBell = { [weak self] in
            guard let self else { return }
            self.delegate?.surfaceDidRingBell(self)
        }
    }

    public func start(_ config: TerminalSurfaceConfig) {
        if let theme = config.theme { applyTheme(theme) }
        let base = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let environment = EnvBuilder.merged(base: base, overrides: config.environment)
        let isDefaultShell = config.command == nil
        let shell = config.command
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
            term.installColors(theme.ansi.map {
                SwiftTerm.Color(red: UInt16($0.red) * 257, green: UInt16($0.green) * 257, blue: UInt16($0.blue) * 257)
            })
        }
        term.nativeBackgroundColor = theme.background.nsColor
        term.nativeForegroundColor = theme.foreground.nsColor
        term.caretColor = theme.cursor.nsColor
        term.selectedTextBackgroundColor = theme.selectionBackground.nsColor
    }

    public func focus() { term.window?.makeFirstResponder(term) }
    public func terminate() { term.terminate() }
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
