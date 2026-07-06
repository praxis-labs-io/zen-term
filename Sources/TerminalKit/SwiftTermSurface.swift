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
