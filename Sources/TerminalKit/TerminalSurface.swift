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
/// shell did not report one; `duration` is in seconds.
public struct TerminalCommandResult: Equatable {
    public var exitCode: Int?
    public var duration: TimeInterval

    public init(exitCode: Int?, duration: TimeInterval) {
        self.exitCode = exitCode
        self.duration = duration
    }
}

/// A move through the scrollback, in the terminal's own units rather than pixels. Lines and page
/// fractions take a signed amount where **positive scrolls down**, toward newer output.
public enum TerminalScroll: Equatable {
    /// Whole lines. A backend clamps at the ends of the buffer.
    case lines(Int)
    /// A fraction of the visible grid's height, so a half page follows the pane's size
    /// rather than a fixed count.
    case pageFraction(Double)
    case top, bottom
    /// To wherever the selection starts. Nothing happens when nothing is selected.
    case selection
    /// A signed count of shell prompts, so `-1` is the prompt above and `1` the one below. Needs
    /// shell integration to know where a prompt is, and a backend without it does nothing. Moves
    /// the viewport, so unlike scroll mode's `{`/`}` it can reach a prompt that scrolled off.
    case prompt(Int)
}

/// Where the viewport sits in the buffer, in lines: `total` rows exist, the viewport starts at
/// `offset` and shows `viewport` of them. `offset + viewport == total` means resting at the bottom.
public struct TerminalScrollPosition: Equatable {
    public var total: Int
    public var offset: Int
    public var viewport: Int

    public init(total: Int, offset: Int, viewport: Int) {
        self.total = total
        self.offset = offset
        self.viewport = viewport
    }

    /// Rows of scrollback below the viewport's last line. Zero when resting at the bottom.
    public var linesBelow: Int { max(0, total - offset - viewport) }
}

/// Where a terminal's character grid sits inside its view, so the chrome can draw *on* the grid
/// rather than near it. All lengths are in **points**, already divided out of whatever backing
/// scale the backend works in.
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

    /// The frame of an inclusive run of cells on one row. Stops at the last cell rather than the
    /// view's edge, since leftover width past the last column holds no characters.
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

/// An inclusive span of cells on the **viewport**, start ordered before end. It cannot extend into
/// the scrollback: libghostty clamps every coordinate to the grid, so no coordinate names a
/// scrollback row.
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

/// One cell on the **viewport**, row 0 at the top of the visible grid. A cell index, never a
/// character offset into the row's text.
public struct TerminalViewportCell: Equatable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// One step through a live search's matches.
public enum TerminalSearchStep: Equatable { case next, previous }

/// What to do with the path after the screen is written to a file. The choice travels in with the
/// call because the backend writes the file and disposes of the path without handing it back.
public enum ScreenFileDisposition: Equatable {
    /// Type the path into the pane, so the next command has something to point at.
    case paste
    /// Put the path on the pasteboard.
    case copy
    /// Open the file in whatever the system opens it with.
    case open
}

/// One keystroke, in the terms a backend keymap needs, and nothing more.
public struct TerminalKey: Equatable {
    /// The macOS virtual keycode. What a backend keymap matches on, because it is the physical
    /// key rather than the glyph a layout happens to put there.
    public var keyCode: UInt16
    public var modifiers: NSEvent.ModifierFlags
    /// The character this key produces with no modifiers held, or 0 for a key that produces none
    /// (the arrows, Return). Some keymaps resolve a bind by glyph and need it.
    public var unshiftedCodepoint: UInt32
    /// The character the keystroke actually types, Shift applied, or nil for a key that types none.
    /// A keymap may hold a bind under either spelling: `⇧-` reaches a bind written `_` only through
    /// this and one written `-` only through `unshiftedCodepoint`.
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

/// What a backend does with a keystroke the chrome did not claim. Four cases rather than a `Bool`,
/// because a bind can run and still pass the key on, and because collapsing the conditional case
/// over-reports what the backend takes.
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
    /// Never round this to `claims`. Bare Escape is bound to end a search, so a probe sees a
    /// binding, yet Escape reaches vim every time no search is running.
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
    /// reset). Only the fill around and under THIS surface follows it; every other chrome color
    /// stays `Theme.current`.
    ///
    /// The color is whatever the terminal now reports rendering, a reset included: there is no
    /// "back on the theme" value, because a reset pins the background to the theme color of that
    /// moment. Foreground, cursor and palette changes get no event.
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor)
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?)
    /// The pointer is over a clickable link (nil when it leaves one). Fires exactly when a click
    /// would open the URL. A `String` rather than a `URL` because an OSC 8 URI is arbitrary
    /// program-chosen text and may not parse.
    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?)
    /// The user clicked the surface's content. The surface reports the intent only; the chrome
    /// stays the single owner of focus.
    func surfaceWantsFocus(_ s: TerminalSurface)
    /// The backend failed to create the underlying terminal. The surface object exists but is
    /// inert. Delivered asynchronously, never synchronously inside `start`, so a consumer that
    /// dispatches on surface identity has finished wiring the surface into its state.
    func surfaceDidFailToStart(_ s: TerminalSurface)
    /// The viewport moved within the buffer, or the buffer grew under it. Fires on output as well
    /// as on `scroll(_:)`. A backend with no scrollback viewport never sends it.
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition)
    /// The grid changed shape, so the text is rewrapping into it. Sent from the size push, ahead of
    /// the backend's reflow: a consumer has to remember what it needs by content now and re-read it
    /// on the next `scrollPositionDidChange`, because measuring here reads the old text.
    ///
    /// Only a change in rows or columns fires it. A backend that resizes fluidly leaves the grid
    /// alone for most pixel changes, and those are not reflows.
    func surfaceGridDidReflow(_ s: TerminalSurface)
    /// How many matches the live needle has, or nil when the backend has none to report. Fires
    /// repeatedly as the engine works back through the buffer, so the count climbs.
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?)
    /// Which match is selected, **zero-based**, or nil when none is. A fresh needle sits at nil
    /// until the first `stepSearch`.
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?)
    /// The backend tore its search down on its own. The chrome takes its find bar down and must
    /// NOT call `endSearch()` back.
    func surfaceDidEndSearch(_ s: TerminalSurface)
    /// The backend asks for a find bar, seeded with `needle` when it has one to offer. A request
    /// rather than a state change: the chrome owns the bar.
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
    func surfaceGridDidReflow(_ s: TerminalSurface) {}
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

    /// The working directory of the surface's shell, resolved live, or nil if the backend can't
    /// determine it. Does not depend on shell-emitted OSC sequences.
    var currentDirectory: URL? { get }

    /// Whether the surface's shell has a running foreground command or a backgrounded job.
    var isBusy: Bool { get }

    /// The background this surface's terminal last reported rendering (OSC 11), or nil while it
    /// has never reported one. The pull half of `surface(_:backgroundDidChange:)`, for a chrome
    /// surface built after the change landed.
    var backgroundOverride: TerminalColor? { get }

    func start(_ config: TerminalSurfaceConfig)
    func focus()

    /// Re-apply appearance/behavior to a RUNNING surface without recreating it. Font, colors,
    /// cursor style/blink and option-as-alt take effect in place; the shell is fixed for the
    /// surface's life. A backend that can't reconfigure live is a no-op.
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior)

    /// Set this surface's font size, in points, overriding the size its theme carried.
    ///
    /// Absolute rather than a delta so the chrome stays the single owner of the number. Separate
    /// from `applyAppearance` because that re-themes through the app-global config, which costs a
    /// synchronous write/read/parse a keyboard-driven auto-repeat cannot afford.
    func setFontSize(_ points: CGFloat)

    /// Explicitly set whether this surface renders as focused (active/blinking cursor) or
    /// unfocused (hollow), driven from the chrome's own single-focus model rather than the AppKit
    /// responder chain, which doesn't propagate reliably while many pane views are reparented in
    /// one pass. Distinct from `focus()`, which also routes first-responder to the surface.
    func setFocused(_ focused: Bool)

    func terminate()

    /// Hold the terminal's grid at its current size while the chrome animates the view's frame,
    /// then reconcile once on resume.
    ///
    /// **Calls nest.** More than one chrome animation can hold the same surface at once, so an
    /// implementation must count holds and reconcile only when the last is released. A release
    /// without a matching hold is ignored rather than counted, so a surface created mid-animation
    /// ends up unheld rather than owing one.
    ///
    /// Without this, every animation frame resizes the surface, and a full-screen TUI hard-wraps
    /// rows that were never wraps: damage that stays in the scrollback after the pane widens back.
    func setSizeSyncSuspended(_ suspended: Bool)

    func paste(_ text: String)
    func copySelection() -> String?

    /// The viewport cell the backend's own selection starts on, or nil when nothing is selected.
    /// Only the near end: no backend here reports where a selection finishes.
    var selectionOrigin: TerminalViewportCell? { get }

    /// Move the viewport through the scrollback.
    func scroll(_ command: TerminalScroll)

    /// Clear the screen and the scrollback with it, the way `clear` does. A terminal on its
    /// alternate screen has nothing to clear and does nothing.
    func clearScreen()

    /// Select everything the buffer holds. The selection is the backend's, so `copySelection`
    /// reads it back.
    func selectAll()

    /// Write the visible screen to a file, and what to do with the path afterwards. The path never
    /// comes back: the backend writes the file and disposes of the path in one action. A backend
    /// that cannot do it is a no-op.
    func writeScreenToFile(_ disposition: ScreenFileDisposition)

    /// The grid's geometry right now, or nil from a backend that has no cells to report or has not
    /// been laid out yet. Read at draw time rather than cached: it moves with the font size and
    /// with every resize.
    var cellMetrics: TerminalCellMetrics? { get }

    /// The text on one viewport row, or nil for a row outside the grid or a backend that cannot
    /// read its own screen. One row at a time, because a backend that unwraps soft-wrapped rows
    /// collapses a multi-row read into fewer lines than the caller asked about.
    func text(viewportRow row: Int) -> String?

    /// The text a span of viewport cells holds, or nil from a backend that cannot read its screen.
    /// Unlike `text(viewportRow:)` this one *wants* soft-wrap unwrapping, so a command line that
    /// wrapped over three rows comes back as the one line it was typed as.
    func text(in range: TerminalViewportRange) -> String?

    /// Run, or re-run, a scrollback search for `needle`. An empty needle stops the engine and
    /// nothing else: the chrome owns the find bar's lifetime.
    func search(_ needle: String)

    /// Step to the next or previous match. Does nothing when no search is running.
    func stepSearch(_ step: TerminalSearchStep)

    /// Tear the search engine down. Idempotent.
    func endSearch()

    /// Deliver a Return **keypress** to the shell, not a pasted `"\r"`. A pasted carriage return
    /// arrives inside bracketed paste, where a TUI reads it as a literal newline rather than a
    /// submit. Paste the text, then call this.
    func submitLine()

    /// What this backend would do with `key` if the chrome passed it through. Answers about the
    /// keymap as configured right now, so a chord's disposition can change under a config reload
    /// and is worth re-asking rather than caching.
    func disposition(of key: TerminalKey) -> ChordDisposition
}

public extension TerminalSurface {
    /// Default no-op: a backend whose cursor already follows the AppKit first responder
    /// needs nothing here.
    func setFocused(_ focused: Bool) {}

    /// A backend with no keymap of its own takes nothing.
    func disposition(of key: TerminalKey) -> ChordDisposition { .ignores }

    /// Backends that can't resolve a cwd get nil for free.
    var currentDirectory: URL? { nil }

    /// Backends that can't inspect the child process report "not busy".
    var isBusy: Bool { false }

    /// Default nil: a backend with no dynamic-color path is always on the theme's background.
    var backgroundOverride: TerminalColor? { nil }

    /// Default nil: a backend that can't report its grid geometry gets no chrome drawn on it.
    var cellMetrics: TerminalCellMetrics? { nil }

    /// Default nil: a backend that can't place its selection is treated as having none.
    var selectionOrigin: TerminalViewportCell? { nil }

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

    /// Default no-ops: a backend that cannot clear, select or dump its own screen leaves the three
    /// chords doing nothing, which is what an unimplemented action should look like.
    func clearScreen() {}
    func selectAll() {}
    func writeScreenToFile(_ disposition: ScreenFileDisposition) {}
}
