import AppKit

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

/// A foreground command's result from shell integration. `exitCode` is nil when the shell reported
/// none; `duration` is in seconds.
public struct TerminalCommandResult: Equatable {
    public var exitCode: Int?
    public var duration: TimeInterval

    public init(exitCode: Int?, duration: TimeInterval) {
        self.exitCode = exitCode
        self.duration = duration
    }
}

/// A move through the scrollback in terminal units. A positive amount scrolls down, toward newer output.
public enum TerminalScroll: Equatable {
    case lines(Int)
    /// A fraction of the visible grid's height.
    case pageFraction(Double)
    case top, bottom
    /// To where the selection starts. Does nothing when nothing is selected.
    case selection
    /// A signed count of shell prompts. Needs shell integration; a backend without it does nothing.
    case prompt(Int)
}

/// The viewport's place in the buffer, in lines. `offset + viewport == total` means at the bottom.
public struct TerminalScrollPosition: Equatable {
    public var total: Int
    public var offset: Int
    public var viewport: Int

    public init(total: Int, offset: Int, viewport: Int) {
        self.total = total
        self.offset = offset
        self.viewport = viewport
    }

    /// Rows of scrollback below the viewport. Zero at the bottom.
    public var linesBelow: Int { max(0, total - offset - viewport) }
}

/// Where the character grid sits inside the surface view, in points.
public struct TerminalCellMetrics: Equatable {
    public var columns: Int
    public var rows: Int
    public var cellWidth: CGFloat
    public var cellHeight: CGFloat
    /// Space before the first cell. Leftover space that fits no whole cell sits at the far edge instead.
    public var gridInset: CGFloat

    public init(columns: Int, rows: Int, cellWidth: CGFloat, cellHeight: CGFloat, gridInset: CGFloat) {
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.gridInset = gridInset
    }

    /// The frame of one viewport row, origin at the top. Clamps `row` to the grid.
    public func rowFrame(_ row: Int, width: CGFloat) -> CGRect {
        let clamped = min(max(row, 0), max(rows - 1, 0))
        return CGRect(
            x: 0, y: gridInset + CGFloat(clamped) * cellHeight, width: width, height: cellHeight)
    }

    /// The frame of an inclusive run of cells on one row, clamped to the grid's last column.
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

/// An inclusive span of viewport cells, start before end. Never reaches into the scrollback.
public struct TerminalViewportRange: Equatable {
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int

    /// Orders the two ends, so a reversed span reads the same as a forward one.
    public init(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        let startsFirst =
            startRow < endRow || (startRow == endRow && startColumn <= endColumn)
        self.startRow = startsFirst ? startRow : endRow
        self.startColumn = startsFirst ? startColumn : endColumn
        self.endRow = startsFirst ? endRow : startRow
        self.endColumn = startsFirst ? endColumn : startColumn
    }

    public var rowCount: Int { endRow - startRow + 1 }
}

/// One viewport cell, row 0 at the top. A cell index, never a character offset.
public struct TerminalViewportCell: Equatable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public enum TerminalSearchStep: Equatable { case next, previous }

public enum ScreenFileDisposition: Equatable {
    /// Types the path into the pane.
    case paste
    case copy
    case open
}

public struct TerminalKey: Equatable {
    /// The macOS virtual keycode: the physical key, not the glyph a layout puts there.
    public var keyCode: UInt16
    public var modifiers: NSEvent.ModifierFlags
    /// The character with no modifiers held, or 0 for a key that types none.
    public var unshiftedCodepoint: UInt32
    /// The character typed with Shift applied, or nil. A bind written `_` matches `⇧-` only through this.
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
public enum ChordDisposition: Equatable {
    /// Reaches the program unchanged.
    case ignores
    /// Runs an action and swallows the key.
    case claims
    /// Runs an action and passes the key on.
    case claimsButPasses
    /// Runs the action only when it would do something, else passes the key. Never treat as `claims`:
    /// bare Escape ends a search but reaches vim whenever no search is running.
    case mayClaim
}

public protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ s: TerminalSurface, titleDidChange title: String)
    func surface(_ s: TerminalSurface, cwdDidChange url: URL)
    func surfaceDidRingBell(_ s: TerminalSurface)
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification)
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?)
    func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult)
    /// The program repainted this surface's background (OSC 11, or an OSC 111 reset to the current
    /// theme color). Foreground, cursor and palette changes send nothing.
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor)
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?)
    /// The pointer entered a clickable link, or left one (nil). A `String` because an OSC 8 URI may not parse.
    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?)
    /// The user clicked the content. The chrome decides whether focus moves.
    func surfaceWantsFocus(_ s: TerminalSurface)
    /// The backend could not create the terminal and the surface is inert. Never sent synchronously
    /// inside `start`.
    func surfaceDidFailToStart(_ s: TerminalSurface)
    /// The viewport moved or the buffer grew under it, from output or `scroll(_:)`.
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition)
    /// Rows or columns changed, sent before the reflow. Note content-anchored state now and re-read it
    /// on the next `scrollPositionDidChange`.
    func surfaceGridDidReflow(_ s: TerminalSurface)
    /// The live needle's match count, or nil. Climbs repeatedly while the search runs.
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?)
    /// The selected match, zero-based, or nil. A fresh needle stays nil until the first `stepSearch`.
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?)
    /// The backend ended its search on its own. Close the find bar without calling `endSearch()`.
    func surfaceDidEndSearch(_ s: TerminalSurface)
    /// The backend asks the chrome to open its find bar, seeded with `needle`.
    func surface(_ s: TerminalSurface, wantsSearchWithNeedle needle: String)
}

/// Default no-ops, so a consumer implements only the events it needs.
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

public protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var delegate: TerminalSurfaceDelegate? { get set }
    var title: String { get }
    var isFocused: Bool { get }

    /// The shell's working directory, resolved live without OSC 7, or nil.
    var currentDirectory: URL? { get }

    /// Whether the shell is running a foreground command.
    var isBusy: Bool { get }

    /// The background the terminal last reported (OSC 11), or nil if it never has.
    var backgroundOverride: TerminalColor? { get }

    func start(_ config: TerminalSurfaceConfig)
    func focus()

    /// Re-applies font, colors, cursor and option-as-alt to a running surface. The shell never changes.
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior)

    /// Overrides the theme's font size, in points. Cheap enough for key auto-repeat, unlike `applyAppearance`.
    func setFontSize(_ points: CGFloat)

    /// Sets whether the cursor renders focused, from the chrome's focus model. Unlike `focus()`, leaves
    /// the first responder alone.
    func setFocused(_ focused: Bool)

    func terminate()

    /// Holds the grid size while the chrome animates the frame, reconciling when the last hold releases.
    /// Calls nest; an unmatched release is ignored.
    func setSizeSyncSuspended(_ suspended: Bool)

    func paste(_ text: String)
    func copySelection() -> String?

    /// The viewport cell the selection starts on, or nil when nothing is selected.
    var selectionOrigin: TerminalViewportCell? { get }

    func scroll(_ command: TerminalScroll)

    /// Clears the screen and scrollback like `clear`. Does nothing on the alternate screen.
    func clearScreen()

    /// Selects the whole buffer, readable through `copySelection`.
    func selectAll()

    /// Writes the visible screen to a file and applies `disposition` to its path. The path is not returned.
    func writeScreenToFile(_ disposition: ScreenFileDisposition)

    /// The grid's geometry now, or nil before layout. Read at draw time; it moves with font and size.
    var cellMetrics: TerminalCellMetrics? { get }

    /// The text on one viewport row, or nil outside the grid.
    func text(viewportRow row: Int) -> String?

    /// The text in `range`, with soft-wrapped rows joined into one line.
    func text(in range: TerminalViewportRange) -> String?

    /// Runs or re-runs a scrollback search. An empty needle stops the engine only.
    func search(_ needle: String)

    /// Does nothing when no search is running.
    func stepSearch(_ step: TerminalSearchStep)

    /// Idempotent.
    func endSearch()

    /// What the backend would do with `key` under the current config. Do not cache across reloads.
    func disposition(of key: TerminalKey) -> ChordDisposition

    /// Tells a surface a modifier moved anywhere in the app. Only a surface on screen in the key window
    /// reports a press; any surface reports the release of a press it reported. Idempotent, so send it
    /// to every surface, the first responder included.
    func modifiersDidChange(_ event: NSEvent)
}

public extension TerminalSurface {
    func setFocused(_ focused: Bool) {}

    func disposition(of key: TerminalKey) -> ChordDisposition { .ignores }

    var currentDirectory: URL? { nil }

    var isBusy: Bool { false }

    var backgroundOverride: TerminalColor? { nil }

    var cellMetrics: TerminalCellMetrics? { nil }

    var selectionOrigin: TerminalViewportCell? { nil }

    func text(viewportRow row: Int) -> String? { nil }

    func text(in range: TerminalViewportRange) -> String? { nil }

    func search(_ needle: String) {}
    func stepSearch(_ step: TerminalSearchStep) {}
    func endSearch() {}

    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {}

    func setFontSize(_ points: CGFloat) {}

    func setSizeSyncSuspended(_ suspended: Bool) {}

    func clearScreen() {}
    func selectAll() {}
    func writeScreenToFile(_ disposition: ScreenFileDisposition) {}

    func modifiersDidChange(_ event: NSEvent) {}
}
