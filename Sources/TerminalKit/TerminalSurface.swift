import AppKit

/// Spawn parameters for a terminal-backed leaf.
public struct TerminalSurfaceConfig {
    public var command: String?
    public var args: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]
    public var fontSize: CGFloat?
    public var theme: TerminalTheme?

    public init(
        command: String? = nil,
        args: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        fontSize: CGFloat? = nil,
        theme: TerminalTheme? = nil
    ) {
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.fontSize = fontSize
        self.theme = theme
    }
}

public struct TerminalNotification {
    public var title: String
    public var body: String
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct TerminalProgress {
    public enum State { case running, paused, error, indeterminate }
    public var state: State
    public var fraction: Double?
    public init(state: State, fraction: Double? = nil) {
        self.state = state
        self.fraction = fraction
    }
}

/// Events flowing OUT of a surface, up into the chrome. Each backend translates
/// its native callbacks into these.
public protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ s: TerminalSurface, titleDidChange title: String)
    func surface(_ s: TerminalSurface, cwdDidChange url: URL)
    func surfaceDidRingBell(_ s: TerminalSurface)
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification)
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?)
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?)
    func surfaceWantsClose(_ s: TerminalSurface)
}

/// Default no-ops so a consumer implements only the events it cares about.
public extension TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {}
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {}
    func surfaceDidRingBell(_ s: TerminalSurface) {}
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {}
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {}
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {}
    func surfaceWantsClose(_ s: TerminalSurface) {}
}

/// The leaf contract. A backend is anything that can BE a terminal in our chrome.
public protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var delegate: TerminalSurfaceDelegate? { get set }
    var title: String { get }
    var isFocused: Bool { get }

    func start(_ config: TerminalSurfaceConfig)
    func focus()
    func terminate()

    func paste(_ text: String)
    func copySelection() -> String?
    func scrollToBottom()
}
