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

/// The result of a foreground command reported by shell integration. `exitCode` is nil when the
/// shell did not report one; `duration` is measured in seconds so the seam does not expose a
/// backend's wire-unit choice.
public struct TerminalCommandResult: Equatable {
    public var exitCode: Int?
    public var duration: TimeInterval

    public init(exitCode: Int?, duration: TimeInterval) {
        self.exitCode = exitCode
        self.duration = duration
    }
}

/// A move through the scrollback, expressed in the terminal's own units rather than pixels.
///
/// Lines and page fractions both take a signed amount where **positive scrolls down**, toward
/// newer output. One vocabulary rather than a `scrollUp`/`scrollDown` pair because the caller
/// is a vim-style keymap, where `j` and `k` differ only in that sign.
public enum TerminalScroll: Equatable {
    /// Whole lines. A backend clamps at the ends of the buffer.
    case lines(Int)
    /// A fraction of the visible grid's height, so a half page follows the pane's size
    /// rather than a fixed count.
    case pageFraction(Double)
    case top, bottom
}

/// Where the viewport sits in the buffer, in lines: `total` rows exist, the viewport starts at
/// `offset` and shows `viewport` of them. `offset + viewport == total` means resting at the
/// bottom. Reported rather than polled, because the numbers move with output as well as with
/// scrolling.
public struct TerminalScrollPosition: Equatable {
    public var total: Int
    public var offset: Int
    public var viewport: Int

    public init(total: Int, offset: Int, viewport: Int) {
        self.total = total
        self.offset = offset
        self.viewport = viewport
    }

    /// Rows of scrollback below the viewport's last line. Zero when resting at the bottom,
    /// which is the distinction a reader needs and neither raw field states on its own.
    public var linesBelow: Int { max(0, total - offset - viewport) }
}

/// Where a terminal's character grid sits inside its view, so the chrome can draw *on* the grid
/// rather than near it. All lengths are in **points**, already divided out of whatever backing
/// scale the backend works in, because the chrome positions AppKit views with them.
///
/// The chrome's scroll-mode cursor is what this exists for: a band on row `n` has to land on the
/// row, and a value derived from the view's bounds instead of the terminal's own numbers is off
/// by the grid inset plus whatever the row height rounds away.
public struct TerminalCellMetrics: Equatable {
    public var columns: Int
    public var rows: Int
    public var cellWidth: CGFloat
    public var cellHeight: CGFloat
    /// Blank space between the view's top-left and the first cell's. Leftover space that does not
    /// divide into a whole cell collects at the far edge, not here, so this is the near inset only.
    public var gridInset: CGFloat

    public init(columns: Int, rows: Int, cellWidth: CGFloat, cellHeight: CGFloat, gridInset: CGFloat) {
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.gridInset = gridInset
    }

    /// The frame of one viewport row, in the surface view's coordinates with the origin at the
    /// top. Clamped to the grid, so a stale row from before a resize cannot draw outside it.
    public func rowFrame(_ row: Int, width: CGFloat) -> CGRect {
        let clamped = min(max(row, 0), max(rows - 1, 0))
        return CGRect(
            x: 0, y: gridInset + CGFloat(clamped) * cellHeight, width: width, height: cellHeight)
    }

    /// The frame of an inclusive run of cells on one row.
    ///
    /// Stops at the last cell rather than the view's edge: leftover width that does not divide into
    /// a cell collects past the last column, where there are no characters to paint over.
    public func cellFrame(row: Int, columns range: ClosedRange<Int>) -> CGRect {
        let last = max(columns - 1, 0)
        let first = min(max(range.lowerBound, 0), last)
        let final = min(max(range.upperBound, first), last)
        let frame = rowFrame(row, width: 0)
        return CGRect(
            x: gridInset + CGFloat(first) * cellWidth, y: frame.origin.y,
            width: CGFloat(final - first + 1) * cellWidth, height: cellHeight)
    }
}

/// An inclusive span of cells on the **viewport**, start ordered before end.
///
/// It cannot extend past the viewport, and that is a backend limit rather than a choice: libghostty
/// resolves an exact coordinate through `Point.pin`, which clamps y to the grid height for every
/// point tag, so no coordinate names a scrollback row.
public struct TerminalViewportRange: Equatable {
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int

    /// Orders the two ends: a reversed span reads back as nothing.
    public init(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        let startsFirst =
            startRow < endRow || (startRow == endRow && startColumn <= endColumn)
        self.startRow = startsFirst ? startRow : endRow
        self.startColumn = startsFirst ? startColumn : endColumn
        self.endRow = startsFirst ? endRow : startRow
        self.endColumn = startsFirst ? endColumn : startColumn
    }

    /// How many rows the span touches, counting the partial ones at each end.
    public var rowCount: Int { endRow - startRow + 1 }
}

/// One step through a live search's matches.
public enum TerminalSearchStep: Equatable { case next, previous }

/// One keystroke, in the terms a backend keymap needs, and nothing more.
///
/// A value type rather than an `NSEvent`, because the caller has no event: the pin-bump baseline
/// asks about a chord nobody pressed. Fabricating an `NSEvent` for that is the trap in
/// `docs/swift-conventions.md`, where a synthesized keystroke is one macOS never sends and the
/// check then passes against the fake.
///
/// `NSEvent.ModifierFlags` rather than a parallel modifier enum: AppKit is not a backend, the seam
/// already hands back an `NSView`, and a second spelling of the same four bits would need
/// converting at both ends for no reader that wants it.
public struct TerminalKey: Equatable {
    /// The macOS virtual keycode. What a backend keymap matches on, because it is the physical
    /// key rather than the glyph a layout happens to put there.
    public var keyCode: UInt16
    public var modifiers: NSEvent.ModifierFlags
    /// The character this key produces with no modifiers held, or 0 for a key that produces none
    /// (the arrows, Return). Some keymaps resolve a bind by glyph and need it.
    public var unshiftedCodepoint: UInt32
    /// The character the keystroke actually types, Shift applied, or nil for a key that types
    /// none. Separate from `unshiftedCodepoint` because a keymap may hold a bind under either
    /// spelling: `⇧-` reaches a bind written `_` only through this, and one written `-` only
    /// through the other, so a probe that sends one of the two is blind to half the keymap.
    public var text: String?

    public init(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, unshiftedCodepoint: UInt32 = 0,
        text: String? = nil
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.unshiftedCodepoint = unshiftedCodepoint
        self.text = text
    }
}

/// What a backend does with a keystroke the chrome did not claim.
///
/// Four cases and not a `Bool`, because "is this bound" and "will this be swallowed" are different
/// questions, and the gap between them is the whole point of asking. A bind can run its action and
/// still hand the key on. A bind can be conditional, so whether it takes the key depends on state
/// no static probe can see. Collapsing any of that over-reports what the backend takes from us,
/// and an audit built on an over-report takes back chords that were never lost.
public enum ChordDisposition: Equatable {
    /// Nothing in the backend claims it, so it reaches the program unchanged.
    case ignores
    /// The backend runs an action and swallows the key. The chord is genuinely gone.
    case claims
    /// The backend runs an action AND passes the key on, so the program sees it too.
    case claimsButPasses
    /// Bound, but conditionally: the backend runs the action only when it would do something, and
    /// otherwise behaves as though the bind does not exist and lets the key through.
    ///
    /// A probe cannot resolve this, and must not round it to `claims`. Bare Escape is the case
    /// that matters: it is bound to end a search, so a probe sees a binding, yet Escape reaches
    /// vim every time no search is running. Rounding up would have listed it as taken.
    case mayClaim
}

/// Events flowing OUT of a surface, up into the chrome. Each backend translates
/// its native callbacks into these.
public protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ s: TerminalSurface, titleDidChange title: String)
    func surface(_ s: TerminalSurface, cwdDidChange url: URL)
    func surfaceDidRingBell(_ s: TerminalSurface)
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification)
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?)
    func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult)
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
    /// The pointer is over a clickable link (nil when it leaves one). The backend decides what
    /// counts as a link and when it is live — for libghostty that is hover with the link
    /// modifier held, the same gate that underlines it and makes it clickable — so this fires
    /// exactly when a click would open the URL. A `String` rather than a `URL` because an OSC 8
    /// URI is arbitrary program-chosen text and may not parse; the chrome shows it, never
    /// resolves it.
    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?)
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
    /// The viewport moved within the buffer, or the buffer grew under it. Fires on output as
    /// well as on `scroll(_:)`, so a chrome surface reading it stays right while a pane keeps
    /// printing. A backend with no notion of a scrollback viewport never sends it.
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition)
    /// How many matches the live needle has, or nil when the backend has none to report. Fires
    /// repeatedly as the engine works back through the buffer, so the count climbs rather than
    /// arriving once.
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?)
    /// Which match is selected, **zero-based**, or nil when none is. A fresh needle sits at nil
    /// until the first `stepSearch`: the backend matches eagerly but selects nothing on its own.
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?)
    /// The backend tore its search down on its own, through a keybind it owns or its own teardown.
    /// The chrome takes its find bar down and must NOT call `endSearch()` back.
    func surfaceDidEndSearch(_ s: TerminalSurface)
    /// The backend asks for a find bar, seeded with `needle` when it has one to offer (libghostty's
    /// search-the-selection binding). A request rather than a state change: the chrome owns the bar.
    func surface(_ s: TerminalSurface, wantsSearchWithNeedle needle: String)
}

/// Default no-ops so a consumer implements only the events it cares about.
public extension TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {}
    func surface(_ s: TerminalSurface, cwdDidChange url: URL) {}
    func surfaceDidRingBell(_ s: TerminalSurface) {}
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {}
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {}
    func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {}
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {}
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {}
    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?) {}
    func surfaceWantsFocus(_ s: TerminalSurface) {}
    func surfaceDidFailToStart(_ s: TerminalSurface) {}
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition) {}
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?) {}
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?) {}
    func surfaceDidEndSearch(_ s: TerminalSurface) {}
    func surface(_ s: TerminalSurface, wantsSearchWithNeedle needle: String) {}
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

    /// Set this surface's font size, in points, overriding the size its theme carried.
    ///
    /// Separate from `applyAppearance` on purpose, and the separation is the whole point rather
    /// than a convenience: `applyAppearance` re-themes through the app-global config, and a backend
    /// configured from files pays a synchronous write/read/parse for each distinct value. That is
    /// affordable for a theme swap and not for a font-size step, which the user drives from the
    /// keyboard and auto-repeats (ZEN-224). This asks for the one value that moves, so a backend can
    /// answer it without rebuilding its configuration.
    ///
    /// Takes an absolute size rather than a delta so the chrome stays the single owner of the
    /// number. A stepping API would leave the running size inside each surface, where the chrome
    /// could not read it back, and surfaces would drift apart at whatever bounds the backend
    /// enforces — which is the shape of the bug this exists to fix.
    func setFontSize(_ points: CGFloat)

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

    /// Move the viewport through the scrollback. The chrome's scroll mode is the caller: it owns
    /// the keymap, and this is the whole of what it needs a terminal to do.
    func scroll(_ command: TerminalScroll)

    /// The grid's geometry right now, or nil from a backend that has no cells to report or has
    /// not been laid out yet. Read at draw time rather than cached: it moves with the font size
    /// and with every resize.
    var cellMetrics: TerminalCellMetrics? { get }

    /// The text on one viewport row, or nil for a row outside the grid or a backend that cannot
    /// read its own screen. One row at a time on purpose: a backend that unwraps soft-wrapped
    /// rows (libghostty does) collapses a multi-row read into fewer lines, and the row a caller
    /// asked about stops being the line it gets back.
    func text(viewportRow row: Int) -> String?

    /// The text a span of viewport cells holds, or nil from a backend that cannot read its screen.
    ///
    /// Unlike `text(viewportRow:)`, this one *wants* a backend's soft-wrap unwrapping: a command
    /// line that wrapped over three rows belongs on the pasteboard as the one line it was typed as.
    func text(in range: TerminalViewportRange) -> String?

    /// Run, or re-run, a scrollback search for `needle`. An empty needle stops the engine and
    /// nothing else: the chrome owns the find bar's lifetime, so stopping the search never takes
    /// the bar down.
    func search(_ needle: String)

    /// Step to the next or previous match. Does nothing when no search is running.
    func stepSearch(_ step: TerminalSearchStep)

    /// Tear the search engine down. Idempotent.
    func endSearch()

    /// Deliver a Return **keypress** to the shell — a real Enter, not a pasted `"\r"`. A pasted
    /// carriage return arrives inside bracketed paste, where a TUI (Claude Code, an editor) reads it
    /// as a literal newline in its input rather than a submit. This is the chrome's way to submit a
    /// line it just pasted (ZEN-257): paste the text, then `submitLine()`.
    func submitLine()

    /// What this backend would do with `key` if the chrome passed it through.
    ///
    /// The chrome resolves its own keymap ahead of the responder chain, so every chord it does not
    /// claim reaches the backend and does whatever the backend's own keymap says. This is how the
    /// chrome finds out what that is, rather than reading it out of the backend's source and
    /// hoping the reading survives the next pin bump.
    ///
    /// Answers about the backend's keymap as configured right now, so a chord's disposition can
    /// change under a config reload and is worth re-asking rather than caching.
    func disposition(of key: TerminalKey) -> ChordDisposition
}

public extension TerminalSurface {
    /// Default no-op: a backend whose cursor already follows the AppKit first responder
    /// needs nothing here.
    func setFocused(_ focused: Bool) {}

    /// A backend with no keymap of its own takes nothing, so it needs no code for this.
    func disposition(of key: TerminalKey) -> ChordDisposition { .ignores }

    /// Backends that can't resolve a cwd get nil for free.
    var currentDirectory: URL? { nil }

    /// Backends that can't inspect the child process report "not busy".
    var isBusy: Bool { false }

    /// Default nil: a backend with no dynamic-color path is always on the theme's background.
    var backgroundOverride: TerminalColor? { nil }

    /// Default nil: a backend that can't report its grid geometry gets no chrome drawn on it.
    var cellMetrics: TerminalCellMetrics? { nil }

    /// Default nil: a backend that can't read its own screen supports no motion over its content.
    func text(viewportRow row: Int) -> String? { nil }

    /// Default nil for the same reason: nothing to read means nothing to yank.
    func text(in range: TerminalViewportRange) -> String? { nil }

    /// Default no-ops: a backend with no search engine supports none of it, and the chrome's find
    /// bar then reports no matches rather than misbehaving.
    func search(_ needle: String) {}
    func stepSearch(_ step: TerminalSearchStep) {}
    func endSearch() {}

    /// Default no-op: a backend that can't reconfigure live needs nothing here.
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {}

    /// Default no-op: a backend with no live font-size path keeps the size it started with.
    func setFontSize(_ points: CGFloat) {}

    /// Default no-op: a backend with no key-injection path can't submit for the chrome.
    func submitLine() {}

    /// Default no-op: a backend that doesn't reflow on every frame change needs nothing here.
    func setSizeSyncSuspended(_ suspended: Bool) {}
}
