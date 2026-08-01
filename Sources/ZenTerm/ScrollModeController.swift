import AppKit
import AppLog
import TerminalKit

/// Scroll mode: a sticky keyboard mode over one focused terminal, where vim keys move the
/// viewport through the scrollback instead of reaching the shell, and `v`/`V`/`y` select and copy
/// out of it.
///
/// It exists because the keys that should scroll a buffer are the ones the shell already owns.
/// `j`, `k`, `⌃d` and `⌃u` cannot be reserved chords without taking them from every program
/// running in every pane, and libghostty's own ⌘Home/⌘PageUp defaults are fn-chords on a laptop
/// that no menu or palette ever mentions. A mode borrows the keys for as long as it is up and
/// gives them back on the way out.
///
/// The mode is per window and targets whichever panel holds unified focus at the moment it
/// opens. It does not follow focus afterward: moving focus ends it, because a scroll mode
/// pointing at a pane you are no longer looking at is a trap rather than a feature.
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
        pendingAnchorLine = nil
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
        refreshCursor()
        onActiveChanged?(true)
    }

    /// Leave the mode and take the header down.
    ///
    /// Idempotent, and deliberately so: every teardown trigger (focus moved, pane closed, tab
    /// switched, window resigned key, surface exited) calls this without first checking whether
    /// one of the others got there first. A sticky mode whose retraction path is conditional is
    /// how you end up with a header over a pane that no longer exists.
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
        pendingAnchorLine = nil
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
    /// Read off the screen rather than from the terminal's cursor. The cursor is the shell's, and
    /// `imePoint` reports it against the *live* screen with no account of scrolling, so a viewport
    /// the reader had already scrolled with the trackpad put the band on an unrelated row. What
    /// the reader means by "where I am" is the last line they can see text on, and the viewport
    /// is the only thing that answers that in every case.
    ///
    /// Falls back to the bottom row when nothing is readable, which is where an empty pane's
    /// prompt sits anyway.
    static func entryRow(of surface: TerminalSurface) -> Int {
        let last = max((surface.cellMetrics?.rows ?? 1) - 1, 0)
        for row in stride(from: last, through: 0, by: -1)
        where !isBlank(surface.text(viewportRow: row)) {
            return row
        }
        return last
    }

    /// Re-place the overlay against the grid's current geometry. For a change that moves the cell
    /// size without moving a view's frame, which is what a font step is: no layout pass runs, so
    /// the overlay never hears about it on its own.
    ///
    /// It also remembers the line the cursor is reading. A step changes the cell size in both
    /// directions, so the grid gains or loses rows and the text rewraps into them: no coordinate
    /// survives that, absolute buffer rows included. The content does.
    func refreshGeometry() {
        guard isActive else { return }
        let line = rowText(cursor.row)
        pendingAnchorLine = Self.isBlank(line) ? nil : line
        invalidateRows()  // a different cell size means different rows
        refreshCursor()
    }

    /// Held until the terminal reports the grid it reflowed into. Nil for a blank row, which has no
    /// content to be found by.
    private var pendingAnchorLine: String?

    /// Nearest match wins: a prompt string repeats down the whole viewport, so a search from the top
    /// would drag the cursor to the first prompt on screen every time.
    private func reanchor(to line: String) {
        var best: Int?
        for row in 0...lastRow where rowText(row) == line {
            if best.map({ abs(row - cursor.row) < abs($0 - cursor.row) }) ?? true { best = row }
        }
        guard let best else { return }
        move(to: ScrollCell(row: best, column: cursor.column))
    }

    /// Whether `s` is the surface the mode is currently driving, so a caller holding a surface
    /// (a pane that just exited) can end only its own mode.
    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    // MARK: keys

    /// Handle one `keyDown` while the mode is up. Returns whether it was consumed.
    ///
    /// An unmapped key is consumed only when it would otherwise reach the shell as input. A mode
    /// that passed those through would drop a stray `x` into the buffer behind it.
    ///
    /// A `⌘` or `⌥` chord is the exception, and getting this wrong is worse than the stray `x`.
    /// `KeyInterceptor` is a local monitor, so it runs *before* `NSApp.sendEvent` resolves menu
    /// key equivalents: swallowing an unmapped `⌘` chord kills ⌘C, ⌘V and ⌘Q for as long as the
    /// mode is up. Those are menu items rather than reserved chords, so nothing above here claims
    /// them, and the mode has to decline them explicitly.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        guard let command = Self.command(for: event, afterG: sawG) else {
            sawG = false
            return event.modifierFlags.intersection([.command, .option]).isEmpty
        }
        if command != .pendingTop { sawG = false }
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
            releaseForScrolling()
            switch move {
            case .top: cursor = ScrollCell(row: 0, column: cursor.column)
            case .bottom: cursor = ScrollCell(row: lastRow, column: cursor.column)
            default: break
            }
            invalidateRows()  // the viewport is about to move
            surface?.scroll(move)
            refreshCursor()
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
            releaseForScrolling()
            invalidateRows()  // the viewport is about to move
            surface?.scroll(.lines(delta))  // pinned at an edge: the buffer moves under the cursor
            refreshCursor()
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

    /// Vim's paragraph motion over the viewport: from `row`, step past any blank rows we are
    /// already sitting in, cross the block of text, and land on the blank row after it.
    ///
    /// This is the chrome's own motion rather than libghostty's `jump_to_prompt`, and it has to
    /// be. `jump_to_prompt` scrolls the viewport to a prompt ABOVE the screen, so it cannot reach
    /// any of the prompts you are looking at, and in a pane with no scrollback it does nothing at
    /// all while three prompts sit on screen. The C API exposes no prompt marks (`ghostty.h` has
    /// only a window-title action), so a cursor cannot be moved to a prompt at all. A blank line
    /// is what vim actually keys off, it is readable from the text, and in a terminal it is what
    /// separates one command's output from the next.
    ///
    /// Clamped to the viewport. A paragraph beyond the visible rows needs the buffer moved first,
    /// which is what the page keys are for.
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
    /// Each miss is a renderer-mutex-locked read. Crossing a blank-line-free block (a build log,
    /// `ls -l`) is one per row, and a held `}` or `w` at key-repeat would multiply that by the
    /// repeat rate against the thread the chrome's responsiveness depends on. Held keys re-walk
    /// mostly the same rows, so caching per viewport state is what takes the repeat rate out of it.
    ///
    /// A row the backend declines caches as empty; nothing downstream tells that from a blank row.
    /// Every path that can move the viewport or resize the grid clears this.
    private func rowText(_ row: Int) -> String {
        if let known = rowCache[row] { return known }
        let text = surface?.text(viewportRow: row) ?? ""
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

    /// Give the anchor back before the viewport moves.
    ///
    /// A selection is viewport-bounded because `Point.pin` clamps an exact coordinate's y to the
    /// grid height for every point tag, so no coordinate names a scrollback row. One that outlived a
    /// scroll would highlight rows it no longer covers and yank text the reader never saw.
    private func releaseForScrolling() {
        guard selection != nil else { return }
        selection = nil
        updateHeader()
    }

    /// The pulse comes after the write, not on the keystroke: a yank leaves nothing on screen, so a
    /// copy that silently didn't take would look exactly like one that did.
    private func yank() {
        guard let surface, let selection, let columns = surface.cellMetrics?.columns else { return }
        let range = selection.range(to: cursor, columns: columns)
        guard let text = surface.text(in: range), !text.isEmpty else { return }
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
        cursor = ScrollCell(
            row: min(cursor.row, lastRow), column: min(cursor.column, lastColumn(of: cursor.row)))
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
        lastPosition = position
        // The first report after a geometry change is the reflowed grid: libghostty emits the
        // scrollbar only from a draw, and only when it differs from the last one sent.
        if let line = pendingAnchorLine {
            pendingAnchorLine = nil
            reanchor(to: line)
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
