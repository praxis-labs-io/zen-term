import AppKit
import SwiftTerm

/// SwiftTerm-backed terminal surface. The only type in TerminalKit that touches
/// SwiftTerm. Bell / notify / progress live on TerminalDelegate (below this view
/// delegate) and are the subject of the Task 8 spike, not wired here.
public final class SwiftTermSurface: NSObject, TerminalSurface {
    private let term = LocalProcessTerminalView(frame: .zero)
    private var lastTitle = ""

    public weak var delegate: TerminalSurfaceDelegate?

    public var view: NSView { term }
    public var title: String { lastTitle }
    public var isFocused: Bool { term.window?.firstResponder === term }

    public override init() {
        super.init()
        term.processDelegate = self
    }

    public func start(_ config: TerminalSurfaceConfig) {
        let base = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let environment = EnvBuilder.merged(base: base, overrides: config.environment)
        let shell = config.command
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"

        term.startProcess(
            executable: shell,
            args: config.args,
            environment: environment,
            execName: nil,
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
