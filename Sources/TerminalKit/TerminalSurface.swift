import AppKit

/// Spawn parameters for a terminal-backed leaf.
public struct TerminalSurfaceConfig {
    public var command: String?
    public var args: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]
    public var fontSize: CGFloat?
    public var theme: TerminalTheme?
    public var behavior: TerminalBehavior?

    public init(
        command: String? = nil,
        args: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        fontSize: CGFloat? = nil,
        theme: TerminalTheme? = nil,
        behavior: TerminalBehavior? = nil
    ) {
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.fontSize = fontSize
        self.theme = theme
        self.behavior = behavior
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
    /// The program running in this surface repainted its own background (OSC 11, or an OSC 111
    /// reset). Only the fill the chrome paints around and under THIS surface follows it: the
    /// pane's padding ring and the layer behind the grid, so a repainted pane still reads as one
    /// surface. Every other chrome color stays `Theme.current`, because a program may recolor its
    /// own pane and never the app frame around it.
    ///
    /// The color is whatever the terminal now reports rendering, a reset included. There is no
    /// "back on the theme" value, because a reset does not put the terminal back on a theme that
    /// can still move: it pins the background to the theme color of that moment. Mirroring the
    /// reported color is what keeps the chrome matched to the grid once the theme changes under
    /// both.
    ///
    /// Foreground, cursor and palette changes get no event: the terminal draws those itself
    /// and no chrome surface mirrors them, so there is nothing for the chrome to do.
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor)
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?)
    func surfaceWantsClose(_ s: TerminalSurface)
    /// The user clicked the surface's content — the chrome should route unified focus
    /// (halo + first-responder) to this surface. The surface only reports the intent;
    /// the chrome stays the single owner of focus.
    func surfaceWantsFocus(_ s: TerminalSurface)
    /// The backend failed to create the underlying terminal (e.g. `ghostty_surface_new`
    /// returned nil). The surface object exists but is inert; the chrome should surface
    /// feedback and offer retry/close rather than leave a dead blank pane. Delivered
    /// asynchronously (never synchronously inside `start`), so a consumer that dispatches
    /// on surface identity can rely on having finished wiring the surface into its state.
    func surfaceDidFailToStart(_ s: TerminalSurface)
}

/// Default no-ops so a consumer implements only the events it cares about.
public extension TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {}
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {}
    func surfaceDidRingBell(_ s: TerminalSurface) {}
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {}
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {}
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {}
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {}
    func surfaceWantsClose(_ s: TerminalSurface) {}
    func surfaceWantsFocus(_ s: TerminalSurface) {}
    func surfaceDidFailToStart(_ s: TerminalSurface) {}
}

/// The leaf contract. A backend is anything that can BE a terminal in our chrome.
public protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var delegate: TerminalSurfaceDelegate? { get set }
    var title: String { get }
    var isFocused: Bool { get }

    /// The working directory of the surface's shell, resolved live (e.g. from the
    /// child process), or nil if the backend can't determine it. Lets the chrome
    /// label tabs and inherit cwd without depending on shell-emitted OSC sequences.
    var currentDirectory: URL? { get }

    /// Whether the surface's shell has a running foreground command or a
    /// backgrounded job. Lets the chrome warn before closing live work.
    var isBusy: Bool { get }

    /// The background this surface's terminal last reported rendering (OSC 11), or nil while it
    /// has never reported one. The pull half of `surface(_:backgroundDidChange:)`, for a chrome
    /// surface built after the change landed: a tool float is torn down to its surface when
    /// hidden and gets a fresh card on re-open, which would otherwise come back on the theme
    /// color while the terminal inside it stayed repainted.
    var backgroundOverride: TerminalColor? { get }

    func start(_ config: TerminalSurfaceConfig)
    func focus()

    /// Re-apply appearance/behavior to a RUNNING surface without recreating it (hot reload).
    /// Font, colors, cursor style/blink, option-as-alt take effect in place; the shell is fixed
    /// for the surface's life. A backend that can't reconfigure live is a no-op (default ext).
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior)

    /// Explicitly set whether this surface renders as focused (active/blinking cursor) or
    /// unfocused (hollow). The chrome drives this from its own single-focus model instead of
    /// trusting the AppKit responder chain, which doesn't propagate reliably while many pane
    /// views are reparented in one pass (rapid splits). Distinct from `focus()`, which also
    /// routes keyboard first-responder to the surface.
    func setFocused(_ focused: Bool)

    func terminate()

    /// Hold the terminal's grid at its current size while the chrome animates the view's frame,
    /// then reconcile once on resume.
    ///
    /// **Calls nest.** More than one chrome animation can hold the same surface at once — a drawer
    /// slide holds every surface in the tab while a split-in holds every surface on the canvas, and
    /// those sets intersect. An implementation must count holds and reconcile only when the last
    /// one is released, or whichever animation lands first will thaw a surface another is still
    /// animating. A release without a matching hold is ignored rather than counted, so a surface
    /// created mid-animation (which never took the hold, but still receives the release) ends up
    /// unheld rather than owing one.
    ///
    /// The chrome animates real layout (a drawer slide compresses
    /// the pane canvas over `Motion.pageSlideDuration`), so without this every animation frame
    /// resizes the surface: one 0.28s slide pushes the grid through ~30 widths, and a column
    /// change is a reflow. Ordinary output survives being rewrapped 30 times; a full-frame TUI
    /// does not, because it positions its rows with cursor moves rather than wraps, so every step
    /// narrower than the frame hard-wraps rows that were never wraps — damage that stays in the
    /// scrollback after the pane widens back.
    func setSizeSyncSuspended(_ suspended: Bool)

    func paste(_ text: String)
    func copySelection() -> String?
    func scrollToBottom()

    /// Deliver a Return **keypress** to the shell — a real Enter, not a pasted `"\r"`. A pasted
    /// carriage return arrives inside bracketed paste, where a TUI (Claude Code, an editor) reads it
    /// as a literal newline in its input rather than a submit. This is the chrome's way to submit a
    /// line it just pasted (ZEN-257): paste the text, then `submitLine()`.
    func submitLine()
}

public extension TerminalSurface {
    /// Default no-op: a backend whose cursor already follows the AppKit first responder
    /// needs nothing here.
    func setFocused(_ focused: Bool) {}

    /// Backends that can't resolve a cwd get nil for free.
    var currentDirectory: URL? { nil }

    /// Backends that can't inspect the child process report "not busy".
    var isBusy: Bool { false }

    /// Default nil: a backend with no dynamic-color path is always on the theme's background.
    var backgroundOverride: TerminalColor? { nil }

    /// Default no-op: a backend that can't reconfigure live needs nothing here.
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {}

    /// Default no-op: a backend with no key-injection path can't submit for the chrome.
    func submitLine() {}

    /// Default no-op: a backend that doesn't reflow on every frame change needs nothing here.
    func setSizeSyncSuspended(_ suspended: Bool) {}
}
