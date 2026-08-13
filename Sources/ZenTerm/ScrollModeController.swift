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
    /// One move through the buffer, decoded from a keystroke. Separate from `TerminalScroll` so
    /// the exits and the `g` prefix (neither of which is a scroll) live in the same decode.
    enum Command: Equatable {
        case scroll(TerminalScroll)
        /// A one-line step, which moves the cursor rather than the viewport until the cursor is
        /// pinned at an edge. Kept apart from `.scroll(.lines(±1))` because that distinction is
        /// the whole difference between a cursor and a scrollbar.
        case step(Int)
        /// Vim's paragraph motion: move the cursor to the next blank row in this direction.
        case paragraph(Int)
        /// One cell left or right.
        case column(Int)
        case word(ScrollWordMotion.Motion)
        case lineStart
        case lineEnd
        /// `v` or `V`: open a selection here, swap which kind it is, or close the one that is up.
        case visual(ScrollSelection.Kind)
        case yank
        /// First `g` of `gg`. Arms the prefix; a second `g` tops out.
        case pendingTop
        /// Esc: hand back the selection if there is one, and leave the mode if there is not.
        case cancel
        /// `q` or `i`: leave outright, selection or no selection.
        case exit
    }

    /// Whether the mode is up. The single source of truth for both the key hook and the header.
    private(set) var isActive = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: PanelHostView?
    private var sawG = false

    /// The cell the cursor sits on, 0,0 at the top left. Viewport-relative rather than absolute in
    /// the buffer, so it survives output arriving underneath without any bookkeeping: the row on
    /// screen is the row you are looking at.
    private(set) var cursor = ScrollCell.origin

    var cursorRow: Int { cursor.row }

    /// Nil in normal mode. Holds the anchor only: `cursor` above is the moving end for both modes.
    private(set) var selection: ScrollSelection?

    /// Where a yank lands. The system pasteboard in the app; a test points it at its own board so
    /// running the suite never clobbers what the developer had copied.
    var yankPasteboard: NSPasteboard = .general

    /// See `rowText`.
    private var rowCache: [Int: String] = [:]

    /// The last position reported, so the header can be rewritten between reports without inventing
    /// a count.
    private var lastPosition: TerminalScrollPosition?

    private var flashRange: TerminalViewportRange?
    private var flashLevel: CGFloat = 0
    private var flashTimer: Timer?

    /// Fires whenever the mode opens or closes, so the window can install and remove its key
    /// hook without this type reaching back into `KeyInterceptor`.
    var onActiveChanged: ((Bool) -> Void)?

    // MARK: lifecycle

    /// Enter the mode over `target`, or do nothing if it is already up over the same panel.
    ///
    /// Entering scrolls nothing. A reader who opened the mode by accident sees only the header
    /// appear, and `q` puts it back.
    func begin(surface: AnyObject & TerminalSurface, panel: PanelHostView) {
        guard !isActive else { return }
        self.surface = surface
        self.panel = panel
        sawG = false
        selection = nil
        lastPosition = nil
        pendingAnchor = nil
        isActive = true
        invalidateRows()
        Log.info("scroll mode entered", category: .panes)
        // The header goes up FIRST, and the grid is measured only after it has. A pane's header is
        // hidden until a mode shows it, and showing it moves the content's top constraint down by
        // its height: the terminal loses a row or two and reflows. Reading the cursor row before
        // that landed measured a grid that was about to change out from under it, which is what
        // put the band a row off the prompt.
        updateHeader()
        panel.layoutSubtreeIfNeeded()
        cursor = ScrollCell(row: Self.entryRow(of: surface), column: 0)
        // That layout reflowed the grid, and the surface reports a reflow from inside its own
        // `setFrameSize` — so `reportReflow` already ran, nested in this call, and armed an anchor
        // against whatever row the *last* session left the cursor on. The entry row above is the
        // answer to where the band goes; drop the anchor before a later report can act on it.
        pendingAnchor = nil
        refreshCursor()
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
        sawG = false
        selection = nil
        lastPosition = nil
        pendingAnchor = nil
        invalidateRows()
        panel?.modeMeta = nil
        panel?.setScrollCursor(nil) { nil }
        panel = nil
        surface = nil
        Log.info("scroll mode left", category: .panes)
        onActiveChanged?(false)
    }

    /// The row the mode opens on: the last row of the viewport with anything written on it.
    ///
    /// Read off the screen rather than the terminal's cursor, which reports against the *live*
    /// screen with no account of scrolling, so a viewport already scrolled with the trackpad put
    /// the band on an unrelated row. Falls back to the bottom row when nothing is readable.
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
        let line = rowText(cursor.row)
        pendingAnchor = Self.isBlank(line) ? nil : (line: line, armedAt: now())
        // Only the cursor can be found again afterwards. The anchor is a fixed row index with no
        // content behind it, so a selection kept across the reflow would run from a row that now
        // holds something else.
        releaseSelection()
        invalidateRows()  // a different cell size means different rows
        refreshCursor()
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
    ///
    /// A window drag calls `refreshGeometry` once per row or column boundary it crosses, and the
    /// repeat reads are safe because the row cache still holds the pre-reflow text: `refreshCursor`
    /// re-caches the cursor's row on the way out, and every path that drops the cache clears or
    /// consumes this first.
    private var pendingAnchor: (line: String, armedAt: ContinuousClock.Instant)?

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
        guard let best = exactRow(of: line) ?? fragmentRow(of: line) else { return }
        move(to: ScrollCell(row: best, column: cursor.column))
    }

    /// Nearest match wins: a prompt string repeats down the whole viewport, so a search from the top
    /// would drag the cursor to the first prompt on screen every time.
    private func exactRow(of line: String) -> Int? {
        // The cursor's own row first. A match there is distance 0 and wins nearest outright, and a
        // reflow that only gained or lost rows leaves most lines exactly where they were. The scan
        // below is a `read_text` per row of the viewport, which libghostty asks callers to throttle.
        let here = min(cursor.row, lastRow)
        if rowText(here) == line { return here }
        var best: Int?
        for row in 0...lastRow where rowText(row) == line {
            if best.map({ abs(row - cursor.row) < abs($0 - cursor.row) }) ?? true { best = row }
        }
        return best
    }

    /// The row holding what is left of `line` after a reflow that changed the column count.
    ///
    /// `text(viewportRow:)` reads one row's cells, so a rewrapped line comes back split and no row
    /// carries the whole of what was remembered: narrowing leaves the row holding a prefix of it,
    /// widening leaves a row that has it as a prefix. Either way one text starts with the other.
    ///
    /// Longest shared prefix wins rather than nearest, because every line on screen starts with the
    /// same prompt. Nearest would hand the anchor to a bare `❯` a row away instead of the fragment
    /// fifty characters deep into the line the reader was actually on.
    private func fragmentRow(of line: String) -> Int? {
        var best: (row: Int, shared: Int)?
        for row in 0...lastRow {
            let text = rowText(row)
            guard text.hasPrefix(line) || line.hasPrefix(text) else { continue }
            let shared = min(text.count, line.count)
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
        guard let command = Self.command(for: event, afterG: sawG) else {
            sawG = false
            return event.modifierFlags.intersection([.command, .option]).isEmpty
        }
        if command != .pendingTop { sawG = false }
        // The reader moved on their own, so a re-anchor still waiting on a report is moot. Left
        // armed it fires on whatever report comes next, minutes later, and drags the cursor off
        // the row they chose.
        pendingAnchor = nil
        switch command {
        case .pendingTop:
            sawG = true
        case .exit:
            end()
        case .cancel:
            // Matches the diff viewer: without it the only way out of a mis-anchored selection is
            // out of the mode.
            if selection != nil { closeSelection() } else { end() }
        case .step(let delta):
            step(delta)
        case .paragraph(let delta):
            move(
                to: ScrollCell(
                    row: paragraphRow(from: cursor.row, delta: delta), column: cursor.column))
        case .column(let delta):
            move(to: ScrollCell(row: cursor.row, column: cursor.column + delta))
        case .word(let motion):
            move(to: motion.destination(from: cursor, on: screen()))
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
            switch move {
            case .top: cursor = ScrollCell(row: 0, column: cursor.column)
            case .bottom: cursor = ScrollCell(row: lastRow, column: cursor.column)
            default: break
            }
            surface?.scroll(move)
            refreshCursor()
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
        let next = cursor.row + delta
        if next >= 0 && next <= lastRow {
            move(to: ScrollCell(row: next, column: cursor.column))
        } else {
            surface?.scroll(.lines(delta))  // pinned at an edge: the buffer moves under the cursor
            refreshCursor()
            invalidateRows()
        }
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
    private func screen() -> ScrollWordMotion.Screen {
        ScrollWordMotion.Screen(lastRow: lastRow) { [weak self] row in self?.rowText(row) ?? "" }
    }

    /// A viewport row's text, read at most once per viewport state.
    ///
    /// Each miss is a renderer-mutex-locked read, and a held `}` at key-repeat would multiply one
    /// per row by the repeat rate against the main thread. A row the backend declines caches as
    /// empty. Every path that can move the viewport or resize the grid clears this.
    ///
    /// Trailing blanks come off here: the backend reads untrimmed, so a row filled edge to edge
    /// arrives padded to the grid width, and `$` would park the cursor out in the padding.
    private func rowText(_ row: Int) -> String {
        if let known = rowCache[row] { return known }
        var text = surface?.text(viewportRow: row) ?? ""
        while let last = text.last, last.isWhitespace { text.removeLast() }
        rowCache[row] = text
        return text
    }

    private func isBlankRow(_ row: Int) -> Bool { Self.isBlank(rowText(row)) }

    /// Drop the read-row cache. Called wherever the visible rows can have changed underneath it.
    private func invalidateRows() { rowCache.removeAll(keepingCapacity: true) }

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

    /// Give the anchor back once the rows under it have moved.
    ///
    /// A selection is viewport-bounded because `Point.pin` clamps an exact coordinate's y to the
    /// grid height for every point tag, so no coordinate names a scrollback row. One that outlived a
    /// scroll would highlight rows it no longer covers and yank text the reader never saw.
    ///
    /// A scroll is driven by the report rather than by the key that asked, because the two do not
    /// line up in either direction: output moves the viewport with no key at all, and a `j` at the
    /// end of the buffer moves nothing while looking exactly like one that does. A reflow calls it
    /// straight, since the cursor can be found again by its line and a fixed anchor cannot.
    private func releaseSelection() {
        guard selection != nil else { return }
        selection = nil
        updateHeader()
    }

    /// What a visual selection currently covers, or nil when there is none.
    ///
    /// Search reads this to seed its bar. It cannot use libghostty's own search-the-selection for
    /// it: that reads `Screen.selection`, which the mouse drives, and scroll mode's selection is
    /// the chrome's own overlay that the backend knows nothing about.
    var selectedText: String? {
        guard let surface, let selection, let columns = surface.cellMetrics?.columns else { return nil }
        let text = surface.text(in: selection.range(to: cursor, columns: columns))
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// The pulse comes after the write, not on the keystroke: a yank leaves nothing on screen, so a
    /// copy that silently didn't take would look exactly like one that did.
    private func yank() {
        guard let surface, let selection, let columns = surface.cellMetrics?.columns else { return }
        let range = selection.range(to: cursor, columns: columns)
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

    private func refreshCursor() {
        guard isActive, let surface else { return }
        let columns = surface.cellMetrics?.columns ?? 0
        // The row first, then the column against THAT row: a grid that lost rows leaves the cursor
        // naming one the backend will not read, and its empty text would collapse the column to 0.
        let row = min(cursor.row, lastRow)
        cursor = ScrollCell(row: row, column: min(cursor.column, lastColumn(of: row)))
        panel?.setScrollCursor(
            ScrollCursorView.State(
                cursor: cursor,
                selection: selection?.range(to: cursor, columns: columns),
                flash: flashRange,
                flashLevel: flashLevel)
        ) { [weak surface] in surface?.cellMetrics }
    }

    /// Decode a `keyDown` into a scroll-mode command, or nil for a key the mode does not map.
    ///
    /// Pure and static so the whole keymap is testable without a window or an event loop, the
    /// same seam `DiffPaneTable.vimKey(for:)` uses. `afterG` is the `gg` prefix, passed in rather
    /// than read off the instance for the same reason.
    ///
    /// Shiftedness comes from the modifier flags, never from the character's case: Caps Lock
    /// uppercases too, so reading case would make a single `g` jump to the top whenever Caps Lock
    /// was on, and turn `j` into a dead key.
    static func command(for event: NSEvent, afterG: Bool) -> Command? {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃d/⌃u/⌃f/⌃b are the vim half- and full-page keys. Match Control exactly so ⌘⌃d and
        // friends fall through to whoever owns them.
        if held == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": return .scroll(.pageFraction(0.5))
            case "u": return .scroll(.pageFraction(-0.5))
            case "f": return .scroll(.pageFraction(1))
            case "b": return .scroll(.pageFraction(-1))
            default: return nil
            }
        }
        // Everything else is bare or shifted. ⌘ and ⌥ belong to another handler.
        guard held.isSubset(of: .shift) else { return nil }
        if event.keyCode == Self.escapeKeyCode { return .cancel }
        // Matched on the typed character, the only form that arrives: `charactersIgnoringModifiers`
        // applies Shift, so a US shift+[ reports "{" in both fields.
        switch event.characters {
        case "{": return .paragraph(-1)
        case "}": return .paragraph(1)
        case "$": return .lineEnd
        default: break
        }
        let shift = held.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("j", false), (Self.downArrow, false): return .step(1)
        case ("k", false), (Self.upArrow, false): return .step(-1)
        case ("h", false), (Self.leftArrow, false): return .column(-1)
        case ("l", false), (Self.rightArrow, false): return .column(1)
        case ("w", false): return .word(.next)
        case ("b", false): return .word(.back)
        case ("e", false): return .word(.end)
        case ("0", false): return .lineStart
        case ("v", false): return .visual(.character)
        case ("v", true): return .visual(.line)
        case ("y", false): return .yank
        case (" ", false): return .scroll(.pageFraction(1))
        case ("g", false): return afterG ? .scroll(.top) : .pendingTop
        case ("g", true): return .scroll(.bottom)
        case ("q", false), ("i", false): return .exit
        default: return nil
        }
    }

    private static let escapeKeyCode: UInt16 = 53
    /// Arrow keys arrive as private-use scalars in `charactersIgnoringModifiers`, matched here so
    /// the arrows work without a second keyCode branch.
    private static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    // MARK: the header

    /// Refresh the indicator from a live scroll position. Called on every `SCROLLBAR` report for
    /// the driven surface, so the count tracks output as well as keys.
    func report(position: TerminalScrollPosition, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        invalidateRows()  // output arrived, or a scroll landed
        if let last = lastPosition, position.offset != last.offset { releaseSelection() }
        lastPosition = position
        // The first report after a geometry change is the reflowed grid: libghostty emits the
        // scrollbar only from a draw, and only when it differs from the last one sent.
        if let pending = pendingAnchor {
            pendingAnchor = nil
            if pending.armedAt.duration(to: now()) <= Self.anchorLifetime {
                reanchor(to: pending.line)
            }
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
