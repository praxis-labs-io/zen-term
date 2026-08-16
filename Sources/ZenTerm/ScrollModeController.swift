import AppKit
import AppLog
import TerminalKit

/// Scroll mode: a sticky keyboard mode over one focused terminal, where vim keys move the viewport
/// through the scrollback instead of reaching the shell, and `v`/`V`/`y` select and copy out of it.
///
/// A mode rather than chords because the keys that should scroll a buffer are the ones the shell
/// already owns: `j`, `k`, `⌃d` and `⌃u` cannot be reserved without taking them from every program
/// in every pane.
///
/// Per window, and targets whichever panel holds focus when it opens. It does not follow focus
/// afterward: moving focus ends it, because a mode pointing at a pane you are no longer looking at
/// is a trap.
@MainActor
final class ScrollModeController {
    /// Whether the mode is up. The single source of truth for both the key hook and the header.
    private(set) var isActive = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: PanelHostView?
    /// What earlier keystrokes left armed: the `g` prefix and the count being typed.
    private var pending = ScrollKeymap.Pending()

    /// The cell the cursor sits on, 0,0 at the top left. Viewport-relative rather than absolute in
    /// the buffer, which holds only while the screen does: see `holdViewport`.
    private(set) var cursor = ScrollCell.origin

    var cursorRow: Int { cursor.row }

    /// Nil in normal mode. Holds the anchor only: `cursor` above is the moving end for both modes.
    private(set) var selection: ScrollSelection?

    /// Where a yank lands. The system pasteboard in the app; a test points it at its own board so
    /// running the suite never clobbers what the developer had copied.
    var yankPasteboard: NSPasteboard = .general

    /// See `rowText`.
    private var rowCache: [Int: String] = [:]

    /// The untrimmed read behind `rowCache`, which is what the cell search counts against.
    private var rawCache: [Int: String] = [:]

    /// Offset to cells, per row, alongside `rowCache` and dropped with it. Each miss is a dozen
    /// renderer-mutex reads, and the yank pulse refreshes the band sixty times a second.
    private var cellCache: [Int: [Int: ClosedRange<Int>]] = [:]

    /// The last position reported, so the header can be rewritten between reports without inventing
    /// a count.
    private var lastPosition: TerminalScrollPosition?

    private var flashRange: TerminalViewportRange?
    private var flashLevel: CGFloat = 0
    private var flashTimer: Timer?

    /// Fires whenever the mode opens or closes, so the window can install and remove its key
    /// hook without this type reaching back into `KeyInterceptor`.
    var onActiveChanged: ((Bool) -> Void)?

    /// `*` hands the word under the cursor to whoever owns the find bar. The mode knows nothing
    /// about search, and the window wires the two together.
    var onSearchWord: ((String) -> Void)?

    // MARK: lifecycle

    /// Enter the mode over `target`, or do nothing if it is already up over the same panel.
    ///
    /// Entering scrolls nothing. A reader who opened the mode by accident sees only the header
    /// appear, and `q` puts it back.
    func begin(surface: AnyObject & TerminalSurface, panel: PanelHostView) {
        guard !isActive else { return }
        self.surface = surface
        self.panel = panel
        pending = .init()
        selection = nil
        lastPosition = nil
        pendingAnchor = nil
        cursorLine = nil
        holdsViewport = false
        reflowArmedAt = nil
        cursor = .origin  // the entry row replaces it below; nothing should read the last session's
        isActive = true
        invalidateRows()
        Log.info("scroll mode entered", category: .panes)
        // Read BEFORE the header goes up, and remember the row by its text: the header SIGWINCHes
        // the pty, and a shell redrawing its prompt blanks those rows for a frame.
        // `entryCell` reports the backend's own cell, worked out from pixels. A column is an offset
        // into the row's text, and on a row with a wide character the two name different ones.
        let entry = Self.entryCell(of: surface)
        cursor = ScrollCell(row: entry.row, column: offset(ofCell: entry.column, on: entry.row))
        let entryText = rowText(cursor.row)
        cursorLine = Self.isBlank(entryText) ? nil : entryText
        updateHeader()
        // Lays out now so the size push is queued against the settled frame. The reflow, and the
        // `refreshGeometry` that arms the line above, land on the next turn.
        panel.layoutSubtreeIfNeeded()
        refreshCursor(remembersLine: false)
        onActiveChanged?(true)
    }

    /// Leave the mode and take the header down. Idempotent on purpose: every teardown trigger
    /// calls it without checking whether another got there first, and a sticky mode with a
    /// conditional retraction path leaves a header over a pane that no longer exists.
    func end() {
        guard isActive else { return }
        flashTimer?.invalidate()
        flashTimer = nil
        flashLevel = 0
        flashRange = nil
        isActive = false
        pending = .init()
        selection = nil
        lastPosition = nil
        pendingAnchor = nil
        cursorLine = nil
        invalidateRows()
        // The mode took the viewport off the live end, so leaving hands it back. A reader who
        // entered already scrolled back never held it, and keeps the place they chose.
        if holdsViewport { surface?.scroll(.bottom) }
        holdsViewport = false
        reflowArmedAt = nil
        panel?.modeMeta = nil
        panel?.setScrollCursor(nil) { nil }
        panel = nil
        surface = nil
        Log.info("scroll mode left", category: .panes)
        onActiveChanged?(false)
    }

    /// Where the mode opens: on the backend's own selection if one is up, so a reader who selected
    /// something and then reached for the keyboard keeps their place. Else `entryRow`, at column 0.
    static func entryCell(of surface: TerminalSurface) -> ScrollCell {
        if let origin = surface.selectionOrigin {
            return ScrollCell(row: origin.row, column: origin.column)
        }
        return ScrollCell(row: entryRow(of: surface), column: 0)
    }

    /// Otherwise the last row with anything written on it, read off the screen rather than the
    /// terminal's cursor: that reports against the *live* screen with no account of scrolling.
    static func entryRow(of surface: TerminalSurface) -> Int {
        let last = max((surface.cellMetrics?.rows ?? 1) - 1, 0)
        for row in stride(from: last, through: 0, by: -1)
        where !isBlank(surface.text(viewportRow: row)) {
            return row
        }
        return last
    }

    /// Re-place the overlay against the grid's current geometry, for a change that moves the cell
    /// size without moving a view's frame. A font step runs no layout pass, so the overlay never
    /// hears about it on its own.
    ///
    /// It also remembers the line the cursor is reading, because a step rewraps the text and no
    /// coordinate survives that, absolute buffer rows included. The content does.
    func refreshGeometry() {
        guard isActive else { return }
        pendingAnchor = cursorLine.map { (line: $0, armedAt: now()) }
        reflowArmedAt = now()  // armed even with no line to re-find: the hold reads the same report
        // Only the cursor can be found again afterwards. The anchor is a fixed row index with no
        // content behind it, so a selection kept across the reflow would run from a row that now
        // holds something else.
        releaseSelection()
        invalidateRows()  // a different cell size means different rows
        refreshCursor(remembersLine: false)
    }

    /// The grid this mode is driving changed shape. A resize rewraps the text under a cursor that is
    /// a row number, exactly as a font step does, so it gets the same treatment. Scoped to the
    /// driven surface: every surface in the window reports its own, and a divider drag reflows some
    /// panes and leaves the rest alone.
    func reportReflow(from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        refreshGeometry()
    }

    /// The line to re-find, held until the terminal reports the grid it reflowed into, with the
    /// moment it was armed. Nil for a blank row, which has no content to be found by.
    private var pendingAnchor: (line: String, armedAt: ContinuousClock.Instant)?

    /// The text of the row the cursor sits on, captured every time the cursor is placed rather than
    /// read when a reflow arrives.
    ///
    /// It has to be read while the grid still has the shape the cursor's row was chosen against. A
    /// reflow is announced *after* the new grid is in place, so a cursor on a row the resize cut is
    /// already past the bottom edge by then: `text(viewportRow:)` refuses to read it, and the line
    /// the reader was on is gone with nothing to find it by.
    ///
    /// The trade is staleness. Output that rewrites this row while the cursor sits still leaves it
    /// describing what used to be there. Refreshing it from the scroll report instead would put a
    /// `read_text` on the output path, and one `tick()` can drain many lines in a single turn, so
    /// that buys a main-thread stall rather than a gradually worse number.
    private var cursorLine: String?

    /// How long an armed anchor stays good for. The reflow's own report follows the size push
    /// within a frame or two, so anything this far behind belongs to a different event.
    ///
    /// It needs a bound because the report may never come: libghostty emits a scrollbar only from a
    /// draw and only when the value differs, so a resize that rewraps nothing changes none of
    /// `total`, `offset` or `viewport` and reports nothing at all. Left armed, the anchor fires on
    /// whatever arrives next, which can be a background process printing a line minutes later, and
    /// drags the band off the row the reader chose while they are only looking at it.
    private static let anchorLifetime: Duration = .seconds(1)

    /// The clock the anchor ages against. Injectable so a test can run the window out without
    /// sleeping, the same seam `yankPasteboard` uses.
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// Put the cursor back on the line it was reading, or leave it where it is when that line is no
    /// longer on screen. Exact match first, then the fragment pass below.
    private func reanchor(to line: String) {
        guard let best = exactRow(of: line) ?? fragmentRow(of: line) ?? containedRow(of: line)
        else { return }
        move(to: ScrollCell(row: best, column: cursor.column))
    }

    /// Nearest match wins: a prompt string repeats down the whole viewport, so a search from the top
    /// would drag the cursor to the first prompt on screen every time.
    private func exactRow(of line: String) -> Int? {
        // Outward from the cursor's own row, stopping at the first hit. Nearest is the rule anyway,
        // so the first match in this order is the answer, and a reflow moves a line by a few rows
        // rather than a screenful. Sweeping the viewport instead spent a `read_text` on every row
        // of it, which libghostty asks callers to throttle.
        let here = min(max(cursor.row, 0), lastRow)
        if rowText(here) == line { return here }
        for distance in 1...max(lastRow, 1) {
            // Above before below, which is the tie-break a sweep up from row 0 used to give.
            for row in [here - distance, here + distance] where row >= 0 && row <= lastRow {
                if rowText(row) == line { return row }
            }
        }
        return nil
    }

    /// The row holding what is left of `line` after a rewrap: narrowing leaves a row holding a
    /// prefix of it, widening leaves a row that has it as a prefix.
    private func fragmentRow(of line: String) -> Int? {
        bestRow(matching: line) { text, line in text.hasPrefix(line) || line.hasPrefix(text) }
    }

    /// The same for a cursor on a **continuation** row, which holds a suffix of its logical line,
    /// so widening merges it back in and neither string starts with the other.
    private func containedRow(of line: String) -> Int? {
        // Last, and only where both passes above give up: containment matches far more loosely, and
        // a wrong match moves the band where the stricter passes would have left it still.
        bestRow(matching: line) { text, line in text.contains(line) || line.contains(text) }
    }

    /// The row overlapping `line` most, nearest to the cursor on a tie. Longest run rather than
    /// nearest, or a bare `❯` a row away beats the fragment fifty characters into the real line.
    private func bestRow(matching line: String, overlaps: (String, String) -> Bool) -> Int? {
        var best: (row: Int, shared: Int)?
        for row in 0...lastRow {
            let text = rowText(row)
            guard overlaps(text, line) else { continue }
            let shared = min(text.count, line.count)  // the shorter one is the part they share
            guard shared >= Self.minimumFragmentMatch else { continue }
            let isBetter =
                best.map {
                    shared > $0.shared
                        || (shared == $0.shared && abs(row - cursor.row) < abs($0.row - cursor.row))
                } ?? true
            if isBetter { best = (row, shared) }
        }
        return best?.row
    }

    /// How much of the remembered line a fragment has to share before it counts as the same line.
    /// A rewrapped fragment shares most of it. A prompt row shares a sigil and maybe a short
    /// command, and anchoring to that would jump the band to an unrelated prompt every time the
    /// line the reader was on has left the screen entirely.
    private static let minimumFragmentMatch = 8

    /// Whether `s` is the surface the mode is currently driving, so a caller holding a surface
    /// (a pane that just exited) can end only its own mode.
    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    /// Put the cursor on `cell`, for search, where the reader names a match rather than walking to
    /// it. Closes any selection first, since dragging its far end across the screen to a match
    /// they were only looking for would select everything in between.
    func land(on cell: ScrollCell) {
        guard isActive else { return }
        releaseSelection()
        pendingAnchor = nil
        move(to: cell)
    }

    // MARK: keys

    /// Handle one `keyDown` while the mode is up. Returns whether it was consumed. An unmapped key
    /// is consumed only when it would otherwise reach the shell as input, since a mode that passed
    /// those through would drop a stray `x` into the buffer behind it.
    ///
    /// A `⌘` or `⌥` chord is the exception. `KeyInterceptor` is a local monitor, so it runs before
    /// `NSApp.sendEvent` resolves menu key equivalents: swallowing an unmapped `⌘` chord kills ⌘C,
    /// ⌘V and ⌘Q for as long as the mode is up.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        guard let key = ScrollKeymap.key(for: event, pending: pending, hasSelection: selection != nil)
        else {
            pending = .init()
            return event.modifierFlags.intersection([.command, .option]).isEmpty
        }
        // A digit joins the count and runs nothing, so everything armed stays armed.
        guard case .run(let command) = key else {
            if case .count(let digit) = key { pending.append(digit: digit) }
            return true
        }
        // Running anything consumes what was armed, except that the arming keys below carry the
        // count on: the `2` of `2yy` is typed before the first `y`.
        let carried = pending.count
        pending = .init()
        // The reader moved on their own, so a re-anchor still waiting on a report is moot. Left
        // armed it fires on whatever report comes next, minutes later, and drags the cursor off
        // the row they chose.
        pendingAnchor = nil
        // Nothing announces a repaint, so the row cache cannot outlive one key. See `rowText`.
        invalidateRows()
        switch command {
        case .pendingTop:
            pending = .init(afterG: true, count: carried)
        case .pendingYank:
            pending = .init(afterY: true, count: carried)
        case .pendingFind(let target):
            pending = .init(awaitingFind: target, count: carried)
        case .yankRow(let times):
            yankRows(times)
        case .find(let find, let times):
            lastFind = find
            runFind(find, times: times, isRepeat: false)
        case .repeatFind(let reversed, let times):
            guard let find = lastFind else { break }
            runFind(reversed ? find.reversed : find, times: times, isRepeat: true)
        case .exit:
            end()
        case .cancel:
            // Matches the diff viewer: without it the only way out of a mis-anchored selection is
            // out of the mode.
            if selection != nil { closeSelection() } else { end() }
        case .step(let delta):
            step(delta)
        case .paragraph(let delta, let times):
            var row = cursor.row
            for _ in 0..<times {
                let next = paragraphRow(from: row, delta: delta)
                if next == row { break }  // parked at an end; the rest of the count is spent
                row = next
            }
            move(to: ScrollCell(row: row, column: cursor.column))
        case .column(let delta):
            move(to: ScrollCell(row: cursor.row, column: cursor.column + delta))
        case .word(let motion, let wide, let times):
            let screen = screen(wide: wide)
            var destination = cursor
            for _ in 0..<times {
                let next = motion.destination(from: destination, on: screen)
                if next == destination { break }  // parked at an end; a big count must not spin
                destination = next
            }
            move(to: destination)
        case .firstNonBlank:
            move(to: ScrollCell(row: cursor.row, column: firstNonBlankColumn(of: cursor.row)))
        case .viewportRow(let place, let offset):
            move(to: ScrollCell(row: viewportRow(place, offset: offset), column: cursor.column))
        case .searchWordUnderCursor:
            if let word = wordUnderCursor() { onSearchWord?(word) }
        case .lineStart:
            move(to: ScrollCell(row: cursor.row, column: 0))
        case .lineEnd:
            move(to: ScrollCell(row: cursor.row, column: lastColumn(of: cursor.row)))
        case .visual(let kind):
            openSelection(kind)
        case .yank:
            yank()
        case .scroll(let move):
            // A page move carries the cursor with the viewport, so it keeps its place on screen.
            // The moves that name a destination put the cursor ON it instead, because landing the
            // thing you asked for somewhere in view and leaving the cursor elsewhere makes the
            // cursor a decoration.
            if case .pageFraction(let fraction) = move { return page(fraction) }
            switch move {
            case .top: cursor = ScrollCell(row: 0, column: cursor.column)
            case .bottom: cursor = ScrollCell(row: lastRow, column: cursor.column)
            default: break
            }
            surface?.scroll(move)
            // The viewport moves under a cursor that stayed put, so the line the band is on is
            // about to change with nothing to announce it, and the read below still describes the
            // old screen. Forgotten rather than kept: a resize before the next cursor move would
            // otherwise anchor to a line that has not been under the band since.
            cursorLine = nil
            refreshCursor(remembersLine: false)
            // After the read, not before it: a row read between the request and the frame that
            // serves it describes the old viewport, and cached under the new one it would send a
            // later `}` or `w` walking text that is no longer there.
            invalidateRows()
        }
        return true
    }

    /// Move the cursor one row, and scroll only once it has nowhere left to go.
    ///
    /// This is what makes it a cursor. Scrolling on every `j` would move the whole screen to
    /// track a marker that never moved, which is a scrollbar with extra steps.
    private func step(_ delta: Int) {
        let target = cursor.row + delta
        let landed = min(max(target, 0), lastRow)
        // The cursor takes what it can and the buffer takes the rest, so `12k` eleven rows from the
        // top moves eleven and scrolls one rather than scrolling all twelve.
        if landed != cursor.row { move(to: ScrollCell(row: landed, column: cursor.column)) }
        let overshoot = target - landed
        guard overshoot != 0 else { return }
        surface?.scroll(.lines(overshoot))  // pinned at an edge: the buffer moves under the cursor
        cursorLine = nil  // same as the page moves: the line changes under a cursor that did not
        refreshCursor(remembersLine: false)
        invalidateRows()
    }

    /// Put the cursor on `cell`, clamped into the grid and onto the row's text.
    private func move(to cell: ScrollCell) {
        let row = min(max(cell.row, 0), lastRow)
        cursor = ScrollCell(row: row, column: min(max(cell.column, 0), lastColumn(of: row)))
        refreshCursor()
        if selection != nil { updateHeader() }  // the row count moved with the cursor
    }

    /// The bottom row of the viewport. Zero while the surface has no metrics to report, which
    /// pins the cursor to the top row rather than letting it run off a grid of unknown size.
    private var lastRow: Int { max((surface?.cellMetrics?.rows ?? 1) - 1, 0) }

    /// Zero on a blank row, so the cursor has somewhere to be.
    private func lastColumn(of row: Int) -> Int { max(rowText(row).count - 1, 0) }

    /// The live selection's span, in cells. Nil in normal mode.
    private func selectionRange() -> TerminalViewportRange? {
        guard let selection, let columns = surface?.cellMetrics?.columns else { return nil }
        // Strongly captured: the closure is called before this returns, and a nil fallback here
        // would quietly hand back offsets as cells, which is the bug the mapping exists to fix.
        return selection.range(to: cursor, columns: columns) { self.cells(of: $0) }
    }

    /// The cells the character at `cell.column` occupies: a wide character is two for the one
    /// offset. ASCII is single width, so an all-ASCII row maps straight through and costs nothing.
    private func cells(of cell: ScrollCell) -> ClosedRange<Int> {
        let text = rowText(cell.row)
        let offset = min(max(cell.column, 0), max(text.count - 1, 0))
        guard !text.allSatisfy(\.isASCII) else { return offset...offset }
        if let known = cellCache[cell.row]?[offset] { return known }
        let first = cellStart(ofOffset: offset, on: cell.row)
        // A character is one cell or two, so one probe past its first settles which. A second
        // binary search would cost seven reads to answer the same question.
        let isWide = self.offset(ofCell: first + 1, on: cell.row) == offset
        let span = first...(isWide ? first + 1 : first)
        cellCache[cell.row, default: [:]][offset] = span
        return span
    }

    /// The character offset at a cell, which is how a backend reports where a selection starts.
    /// One read: the row's count less what the cell to the edge holds is how many precede it.
    private func offset(ofCell cell: Int, on row: Int) -> Int {
        guard cell > 0, let surface, let columns = surface.cellMetrics?.columns, cell < columns
        else { return max(cell, 0) }
        let rest = surface.text(
            in: TerminalViewportRange(
                startRow: row, startColumn: cell, endRow: row, endColumn: columns - 1))
        return max(rawRow(row).count - (rest?.count ?? 0), 0)
    }

    /// The first cell holding the character at `offset`, searched from the right: reading cell c to
    /// the edge gives every character from c on, so the row's count less that is how many precede c.
    private func cellStart(ofOffset offset: Int, on row: Int) -> Int {
        guard offset > 0 else { return 0 }
        guard let surface, let columns = surface.cellMetrics?.columns, columns > 0 else {
            return offset
        }
        // From the right because the formatter drops a run of never-written cells at the end of a
        // read, so a prefix stopping inside a cursor-positioned gap comes back short.
        let total = rawRow(row).count
        var low = 0
        var high = columns  // one past the grid, which is what "no such character" reads as
        while low < high {
            let mid = (low + high) / 2
            let rest = surface.text(
                in: TerminalViewportRange(
                    startRow: row, startColumn: mid, endRow: row, endColumn: columns - 1))
            if total - (rest?.count ?? 0) >= offset { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Vim's paragraph motion over the viewport: step past any blank rows, cross the block of
    /// text, land on the blank row after it.
    ///
    /// The chrome's own motion rather than libghostty's `jump_to_prompt`, which scrolls to a
    /// prompt ABOVE the screen and so cannot reach the ones you are looking at. The C API exposes
    /// no prompt marks either, so a blank line is what is left, and it is what vim keys off anyway.
    ///
    /// Clamped to the viewport: a paragraph beyond the visible rows needs the buffer moved first.
    private func paragraphRow(from row: Int, delta: Int) -> Int {
        guard surface != nil, delta != 0 else { return row }
        let limit = lastRow
        var next = row + delta
        while next >= 0 && next <= limit && isBlankRow(next) { next += delta }
        while next >= 0 && next <= limit && !isBlankRow(next) { next += delta }
        return min(max(next, 0), limit)
    }

    /// Reads through the same cache as everything else, so a `w` across the viewport costs no more
    /// locked reads than a `}` over it.
    private func screen(wide: Bool = false) -> ScrollWordMotion.Screen {
        ScrollWordMotion.Screen(lastRow: lastRow, wide: wide) { [weak self] row in
            self?.rowText(row) ?? ""
        }
    }

    /// The first cell on the row holding anything but whitespace, or zero on a blank row.
    private func firstNonBlankColumn(of row: Int) -> Int {
        Array(rowText(row)).firstIndex { !$0.isWhitespace } ?? 0
    }

    /// The row `H`, `M` or `L` names. Reckoned from the last **written** row rather than the grid's
    /// bottom, which on a half-filled screen is empty space below everything there is to read.
    private func viewportRow(_ place: ScrollKeymap.ViewportPlace, offset: Int) -> Int {
        let bottom = lastWrittenRow
        switch place {
        case .top: return min(offset, bottom)
        case .middle: return bottom / 2
        case .bottom: return max(bottom - offset, 0)
        }
    }

    /// The keyword run the cursor sits in, or nil when it is not on one. What `*` searches for.
    private func wordUnderCursor() -> String? {
        let text = Array(rowText(cursor.row))
        guard text.indices.contains(cursor.column),
            ScrollWordMotion.classify(text[cursor.column]) == .keyword
        else { return nil }
        var start = cursor.column
        while start > 0, ScrollWordMotion.classify(text[start - 1]) == .keyword { start -= 1 }
        var end = cursor.column
        while end + 1 < text.count, ScrollWordMotion.classify(text[end + 1]) == .keyword { end += 1 }
        return String(text[start...end])
    }

    /// A row's text, once per keystroke: nothing announces a repaint, so a cache outliving the key
    /// answered from a screen that was gone. Trailing blanks come off, so `$` skips a row's padding.
    private func rowText(_ row: Int) -> String {
        if let known = rowCache[row] { return known }
        var text = rawRow(row)
        while let last = text.last, last.isWhitespace { text.removeLast() }
        rowCache[row] = text
        return text
    }

    /// The row as the backend hands it over, padding and all. `cellStart` counts against this, not
    /// the trimmed text, or a row ending in written spaces maps every cell short by that many.
    private func rawRow(_ row: Int) -> String {
        if let known = rawCache[row] { return known }
        let text = surface?.text(viewportRow: row) ?? ""
        rawCache[row] = text
        return text
    }

    private func isBlankRow(_ row: Int) -> Bool { Self.isBlank(rowText(row)) }

    /// Drop the read-row cache. Called wherever the visible rows can have changed underneath it.
    private func invalidateRows() {
        rowCache.removeAll(keepingCapacity: true)
        rawCache.removeAll(keepingCapacity: true)
        cellCache.removeAll(keepingCapacity: true)
    }

    /// A row counts as blank when it holds no non-whitespace. A row the backend cannot read is
    /// treated as blank so a motion terminates rather than running to the edge of the grid.
    static func isBlank(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.allSatisfy(\.isWhitespace)
    }

    // MARK: selection

    /// The same key twice closes the selection and the other key swaps its kind, as in vim.
    private func openSelection(_ kind: ScrollSelection.Kind) {
        if var current = selection {
            guard current.kind != kind else { return closeSelection() }
            current.kind = kind
            selection = current
        } else {
            selection = ScrollSelection(kind: kind, anchor: cursor)
        }
        updateHeader()
        refreshCursor()
    }

    private func closeSelection() {
        selection = nil
        updateHeader()
        refreshCursor()
    }

    /// Give the anchor back once the rows under it have moved. A selection cannot leave the
    /// viewport, so one that outlived a scroll would highlight rows it no longer covers.
    ///
    /// Driven by the report, not the key: output moves the viewport with no key at all, and a `j`
    /// at the end of the buffer moves nothing while looking exactly like one that does.
    private func releaseSelection() {
        guard selection != nil else { return }
        selection = nil
        updateHeader()
        // The overlay holds the rects it was last handed, so without this the highlight stays
        // painted over rows the selection no longer covers. Remembers nothing: this is not a
        // placement, and `refreshGeometry` calls it before invalidating the rows it would read.
        refreshCursor(remembersLine: false)
    }

    /// What a visual selection currently covers, or nil when there is none.
    ///
    /// Search reads this to seed its bar. It cannot use libghostty's own search-the-selection for
    /// it: that reads `Screen.selection`, which the mouse drives, and scroll mode's selection is
    /// the chrome's own overlay that the backend knows nothing about.
    var selectedText: String? {
        guard let surface, let range = selectionRange() else { return nil }
        let text = surface.text(in: range)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// The pulse comes after the write, not on the keystroke: a yank leaves nothing on screen, so a
    /// copy that silently didn't take would look exactly like one that did.
    private func yank() {
        guard let surface, let range = selectionRange() else { return }
        // An empty span still completes the gesture, blank row and all: dropping out here would
        // leave the screen identical to before the keystroke, which is the confirmation gap the
        // pulse exists to close. Only a read the backend refuses has nothing to confirm.
        guard let text = surface.text(in: range) else {
            Log.warning("scroll mode: the surface declined a yank read", category: .panes)
            return
        }
        yankPasteboard.clearContents()
        yankPasteboard.setString(text, forType: .string)
        self.selection = nil
        updateHeader()
        flash(range)
    }

    /// The last row with anything written on it. Below it is empty space, and no move should land
    /// the band out there. Reads through the cache: `H`/`L` and every page move ask for it.
    private var lastWrittenRow: Int {
        let last = lastRow
        for row in stride(from: last, through: 0, by: -1) where !Self.isBlank(rowText(row)) {
            return row
        }
        return last
    }

    /// A page move: the cursor advances by the fraction and the viewport takes what it can, so the
    /// band parks mid-screen while the buffer runs under it. Against either end the viewport takes
    /// nothing and the cursor makes the rest of the trip, which is the only way to reach the last
    /// half page by paging.
    @discardableResult
    private func page(_ fraction: Double) -> Bool {
        let rows = max(surface?.cellMetrics?.rows ?? 1, 1)
        let advance = Int((fraction * Double(rows)).rounded(.towardZero))
        guard advance != 0 else { return true }
        let down = advance > 0
        let want = cursor.row + advance
        // How far the buffer can still go this way. Unknown before the first report, where
        // assuming room is the better guess: the backend clamps what it cannot do.
        let room = (down ? lastPosition?.linesBelow : lastPosition?.offset) ?? .max
        let ideal = want - lastRow / 2
        let taken = down ? min(max(ideal, 0), room) : max(min(ideal, 0), -room)
        if taken != 0 { surface?.scroll(.lines(taken)) }
        // A page that spends the last of the room lands on a screen this one cannot see yet, so the
        // bottom it clamps to is the old one. The report that follows re-clamps against the new.
        clampsToWrittenRows = down && taken == room
        let landed = down ? min(want - taken, lastWrittenRow) : want - taken
        cursor = ScrollCell(row: min(max(landed, 0), lastRow), column: cursor.column)
        // The buffer moved under the band, so the line it names is about to change with nothing to
        // announce it, and the read below still describes the old screen.
        cursorLine = nil
        refreshCursor(remembersLine: false)
        invalidateRows()  // after the read, never before: see the named scrolls above
        return true
    }

    /// `yy`: copy whole rows without opening a selection first, and pulse what it took.
    private func yankRows(_ times: Int) {
        guard let surface, let columns = surface.cellMetrics?.columns else { return }
        let range = TerminalViewportRange(
            startRow: cursor.row, startColumn: 0,
            endRow: min(cursor.row + times - 1, lastRow), endColumn: max(columns - 1, 0))
        guard let text = surface.text(in: range) else {
            Log.warning("scroll mode: the surface declined a yank read", category: .panes)
            return
        }
        yankPasteboard.clearContents()
        yankPasteboard.setString(text, forType: .string)
        flash(range)
    }

    /// Set by a page that scrolled to the end of the buffer, and spent by the next report.
    private var clampsToWrittenRows = false

    /// The last `f`/`F`/`t`/`T`, so `;` and `,` have something to run again.
    private var lastFind: ScrollKeymap.Find?

    /// `f`/`F`/`t`/`T`: land on, or just before, the next occurrence along this row.
    private func runFind(_ find: ScrollKeymap.Find, times: Int, isRepeat: Bool) {
        let text = Array(rowText(cursor.row))
        var column = cursor.column
        for step in 0..<times {
            // A `t` parks next to its target, so searching again from there finds the same cell.
            // Every hop after the landing starts one further along, counted or repeated.
            let skips = find.till && (isRepeat || step > 0)
            let from = skips ? column + (find.direction == .forward ? 1 : -1) : column
            guard let next = Self.findColumn(find, from: from, in: text) else { return }
            column = next
        }
        move(to: ScrollCell(row: cursor.row, column: column))
    }

    /// Where `find` lands starting from `column`, or nil when the row holds no more of it.
    static func findColumn(_ find: ScrollKeymap.Find, from column: Int, in text: [Character]) -> Int? {
        let stride = find.direction == .forward ? 1 : -1
        var index = column + stride
        while text.indices.contains(index) {
            if text[index] == find.character { return find.till ? index - stride : index }
            index += stride
        }
        return nil
    }

    /// Pulse the yanked span and fade out, the way nvim's `on_yank` does.
    private func flash(_ range: TerminalViewportRange) {
        cancelFlash()
        flashRange = range
        flashLevel = 1
        refreshCursor()
        guard !Motion.isReduceMotionEnabled() else {
            // Still a beat of highlight: the pulse is the confirmation, so it can be made still
            // but not dropped.
            flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashDuration, repeats: false) {
                [weak self] _ in MainActor.assumeIsolated { self?.cancelFlash() }
            }
            return
        }
        let step = CGFloat(Self.flashFrame / Self.flashDuration)
        flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashFrame, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flashLevel -= step
                if self.flashLevel <= 0 { self.cancelFlash() } else { self.refreshCursor() }
            }
        }
    }

    private func cancelFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        guard flashLevel != 0 else { return }
        flashLevel = 0
        flashRange = nil
        refreshCursor()
    }

    /// So a test can assert the confirmation is wired to a copy that landed. Its timing and color
    /// are the runbook's.
    var isFlashingForTesting: Bool { flashLevel > 0 }

    private static let flashDuration: TimeInterval = 0.22
    private static let flashFrame: TimeInterval = 1.0 / 60

    /// `remembersLine` is false for a geometry refresh, which does not change which line the reader
    /// is on: it re-places the band against a grid that is mid-reflow, so the text under the row
    /// describes the rewrap in progress rather than anything they chose. A drag can fire several
    /// reflows before a single scroll report arrives, and letting each one overwrite the remembered
    /// line means the third arms against rewrapped text.
    private func refreshCursor(remembersLine: Bool = true) {
        guard isActive, let surface else { return }
        // The row first, then the column against THAT row: a grid that lost rows leaves the cursor
        // naming one the backend will not read, and its empty text would collapse the column to 0.
        let row = min(cursor.row, lastRow)
        let text = rowText(row)
        cursor = ScrollCell(row: row, column: min(cursor.column, max(text.count - 1, 0)))
        // Remembered here, while the grid still has the shape this row was chosen against. See
        // `cursorLine` for why it cannot wait until a reflow asks for it.
        if remembersLine { cursorLine = Self.isBlank(text) ? nil : text }
        panel?.setScrollCursor(
            ScrollCursorView.State(
                cursorRow: cursor.row,
                cursorCells: cells(of: cursor),
                selection: selectionRange(),
                flash: flashRange,
                flashLevel: flashLevel)
        ) { [weak surface] in surface?.cellMetrics }
    }

    /// Whether the mode pulled the viewport off the live end, so leaving can hand it back.
    private var holdsViewport = false

    /// Put the viewport back when output pushed it under the band, and say whether it did.
    /// libghostty pins any viewport above the active area, so one pull holds the whole visit.
    private func holdViewport(against position: TerminalScrollPosition) -> Bool {
        guard !awaitsReflow, position.linesBelow == 0, let last = lastPosition else { return false }
        // Output at the live end grows the buffer and moves the viewport by the same rows, where a
        // scroll the reader asked for moves the viewport alone. A rewrap does both: hence the guard.
        let growth = position.total - last.total
        guard growth > 0, position.offset - last.offset == growth else { return false }
        holdsViewport = true
        surface?.scroll(.lines(-growth))
        return true
    }

    /// When the grid last reflowed. A narrowing drag rewraps rows into the buffer and, at the live
    /// end, moves the viewport by exactly as many, which is the signature output has.
    private var reflowArmedAt: ContinuousClock.Instant?

    /// Bounded like `pendingAnchor`, and for the same reason: the report may never come, because
    /// libghostty emits a scrollbar only when the value differs from the last one sent.
    private var awaitsReflow: Bool {
        guard let armed = reflowArmedAt else { return false }
        return armed.duration(to: now()) <= Self.anchorLifetime
    }

    // MARK: the header

    /// Refresh the indicator from a live scroll position. Called on every `SCROLLBAR` report for
    /// the driven surface, so the count tracks output as well as keys.
    func report(position: TerminalScrollPosition, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        // Before the hold, which returns: the same burst can rewrite a visible cell as well as
        // push the view, and the pull back restores the viewport but not what the rows now say.
        invalidateRows()
        if holdViewport(against: position) { return }
        reflowArmedAt = nil
        if let last = lastPosition, position.offset != last.offset {
            releaseSelection()
            // The reader, or the find bar, put the viewport here. Leaving hands back only what the
            // mode itself took, so a place they chose survives `q`.
            holdsViewport = false
        }
        lastPosition = position
        // The first report after a geometry change is the reflowed grid: libghostty emits the
        // scrollbar only from a draw, and only when it differs from the last one sent.
        if let pending = pendingAnchor {
            pendingAnchor = nil
            if pending.armedAt.duration(to: now()) <= Self.anchorLifetime {
                reanchor(to: pending.line)
            }
        }
        if clampsToWrittenRows {
            clampsToWrittenRows = false
            let bottom = lastWrittenRow
            if cursor.row > bottom { move(to: ScrollCell(row: bottom, column: cursor.column)) }
        }
        updateHeader()
    }

    private func updateHeader() {
        let title =
            selection.map {
                Self.visualTitle(kind: $0.kind, rows: abs(cursor.row - $0.anchor.row) + 1)
            } ?? Self.headerTitle(lastPosition)
        panel?.modeMeta = PanelMeta(title: title, action: .toggleScrollMode)
    }

    /// What the pane header reads. "Scroll" alone until the terminal has reported a position,
    /// because a count invented before the first report would be wrong rather than absent.
    static func headerTitle(_ position: TerminalScrollPosition?) -> String {
        guard let position else { return "Scroll" }
        let below = position.linesBelow
        if below == 0 { return "Scroll: at bottom" }
        return "Scroll: \(groupedCount(below)) below"
    }

    /// A charwise selection gets no count: the number that would mean anything is characters, and it
    /// moves on every `l`.
    static func visualTitle(kind: ScrollSelection.Kind, rows: Int) -> String {
        switch kind {
        case .character: return "Visual"
        case .line: return "Visual: \(groupedCount(rows)) \(rows == 1 ? "line" : "lines")"
        }
    }

    /// A row count grouped for the reader's locale. Exposed so a test can build the expected
    /// string the same way instead of hardcoding one locale's separator.
    static func groupedCount(_ value: Int) -> String {
        lineCount.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let lineCount: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
