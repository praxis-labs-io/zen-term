import AppKit
import AppLog
import TerminalKit

@MainActor
final class ScrollModeController {
    private(set) var isActive = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: TerminalModeHost?
    private var pending = ScrollKeymap.Pending()

    private var cursorMark: TerminalGridMark?

    var cursor: TerminalGridPoint? { Self.point(of: cursorMark) }

    private(set) var selection: ScrollSelection?

    var yankPasteboard: NSPasteboard = .general

    private var lastPosition: TerminalScrollPosition?
    private var lastGridSize: GridSize?

    private var flashRange: ClosedRange<TerminalGridPoint>?
    private var flashLevel: CGFloat = 0
    private var flashTimer: Timer?

    private var lastFind: ScrollKeymap.Find?

    private var holdsViewport = false

    var onActiveChanged: ((Bool) -> Void)?

    var onSearchWord: ((String) -> Void)?

    private struct GridSize: Equatable {
        var columns: Int
        var rows: Int
    }

    private var grid: TerminalGrid? { surface?.grid }

    func begin(surface: AnyObject & TerminalSurface, panel: TerminalModeHost) {
        guard !isActive else { return }
        self.surface = surface
        self.panel = panel
        pending = .init()
        lastPosition = nil
        lastGridSize = Self.gridSize(of: surface)
        holdsViewport = false
        isActive = true
        Log.info("scroll mode entered", category: .panes)
        if let grid = surface.grid {
            lastPosition = TerminalScrollPosition(
                total: grid.rowCount, offset: grid.viewportTop, viewport: screenRows)
            if let mouse = grid.selectionBounds, let anchor = grid.mark(mouse.upperBound) {
                selection = ScrollSelection(kind: .character, anchor: anchor)
                seat(at: mouse.lowerBound)
                reveal()
            } else if let shell = grid.cursorPoint {
                seat(at: shell)
                keepCursorInView()
            }
        }
        panel.layoutSubtreeIfNeeded()
        refreshCursor()
        onActiveChanged?(true)
    }

    func end() {
        guard isActive else { return }
        flashTimer?.invalidate()
        flashTimer = nil
        flashLevel = 0
        flashRange = nil
        isActive = false
        pending = .init()
        if selection != nil {
            selection = nil
            grid?.setSelection(nil)
        }
        cursorMark = nil
        lastPosition = nil
        lastGridSize = nil
        if holdsViewport { surface?.scroll(.bottom) }
        holdsViewport = false
        panel?.setScrollCursor(nil) { nil }
        panel = nil
        surface = nil
        Log.info("scroll mode left", category: .panes)
        onActiveChanged?(false)
    }

    /// A font step changes the cell size without a resize report.
    func refreshGeometry() {
        guard isActive else { return }
        refreshCursor()
    }

    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    func land(on point: TerminalGridPoint) {
        guard isActive else { return }
        releaseSelection()
        move(to: point)
    }

    /// Only a selection gone while the mode holds one means ghostty cleared it: the mode's own sets report too.
    func reportSelectionChange(from s: AnyObject) {
        guard isActive, isDriving(s), selection != nil, grid?.selectionBounds == nil else { return }
        selection = nil
        end()
    }

    /// Declines unmapped ⌘ and ⌥ chords: `KeyInterceptor` runs before menu key equivalents resolve.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        guard let key = ScrollKeymap.key(for: event, pending: pending, hasSelection: selection != nil)
        else {
            pending = .init()
            return event.modifierFlags.intersection([.command, .option]).isEmpty
        }
        guard case .run(let command) = key else {
            if case .count(let digit) = key { pending.append(digit: digit) }
            return true
        }
        let carried = pending.count
        pending = .init()
        if cursor == nil { keepCursorInView() }
        run(command, carried: carried)
        return true
    }

    private func run(_ command: ScrollKeymap.Command, carried: Int?) {
        switch command {
        case .pendingTop:
            pending = .init(afterG: true, count: carried)
        case .pendingYank:
            pending = .init(afterY: true, count: carried)
        case .pendingFind(let target):
            pending = .init(awaitingFind: target, count: carried)
        case .yankRow(let times):
            yankLines(times)
        case .find(let find, let times):
            lastFind = find
            runFind(find, times: times, isRepeat: false)
        case .repeatFind(let reversed, let times):
            guard let find = lastFind else { break }
            runFind(reversed ? find.reversed : find, times: times, isRepeat: true)
        case .exit:
            end()
        case .cancel:
            if selection != nil { closeSelection() } else { end() }
        case .visual(let kind):
            openSelection(kind)
        case .yank:
            yank()
        case .searchWordUnderCursor:
            if let word = wordUnderCursor() { onSearchWord?(word) }
        case .scroll(let scroll):
            self.scroll(scroll)
        default:
            guard let cursor, let destination = destination(of: command, from: cursor) else { return }
            move(to: destination)
        }
    }

    private func destination(of command: ScrollKeymap.Command, from cursor: TerminalGridPoint) -> TerminalGridPoint? {
        switch command {
        case .step(let delta):
            return textPoint(column: cursor.column, row: cursor.row + delta)
        case .paragraph(let delta, let times):
            return textPoint(column: cursor.column, row: paragraphRow(from: cursor.row, delta: delta, times: times))
        case .column(let delta):
            return stepped(cursor, by: delta)
        case .word(let motion, let wide, let times):
            let screen = wordScreen(wide: wide)
            var destination = cursor
            for _ in 0..<times {
                let next = motion.destination(from: destination, on: screen)
                if next == destination { break }
                destination = next
            }
            return destination
        case .firstNonBlank:
            let first = line(cursor.row).first { !$0.character.isWhitespace }?.column ?? 0
            return TerminalGridPoint(row: cursor.row, column: first)
        case .viewportRow(let place, let offset):
            return textPoint(column: cursor.column, row: viewportRow(place, offset: offset))
        case .lineStart:
            return TerminalGridPoint(row: cursor.row, column: 0)
        case .lineEnd:
            return TerminalGridPoint(row: cursor.row, column: lastWrittenColumn(of: cursor.row))
        default:
            return nil
        }
    }

    private func scroll(_ scroll: TerminalScroll) {
        switch scroll {
        case .pageFraction(let fraction): page(fraction)
        case .top:
            surface?.scroll(.top)
            if let cursor { move(to: textPoint(column: cursor.column, row: 0)) }
        case .bottom:
            surface?.scroll(.bottom)
            if let cursor { move(to: textPoint(column: cursor.column, row: lastWrittenRow)) }
        default:
            surface?.scroll(scroll)
            keepCursorInView()
            refreshCursor()
        }
    }

    private func seat(at point: TerminalGridPoint) {
        guard let grid else { return }
        let row = min(max(point.row, 0), max(grid.rowCount - 1, 0))
        var column = max(point.column, 0)
        let cells = grid.row(row)?.cells ?? []
        column = min(column, max(cells.count - 1, 0))
        if cells.indices.contains(column), cells[column].width == 0, column > 0 { column -= 1 }
        cursorMark = grid.mark(TerminalGridPoint(row: row, column: column))
    }

    private func move(to point: TerminalGridPoint) {
        seat(at: point)
        reveal()
        applySelection()
        refreshCursor()
    }

    private var rowCount: Int { grid?.rowCount ?? 0 }

    private var screenRows: Int { max(surface?.cellMetrics?.rows ?? 1, 1) }

    private func cells(_ row: Int) -> [TerminalGridCell] { grid?.row(row)?.cells ?? [] }

    private func line(_ row: Int) -> [(column: Int, character: Character)] {
        ScrollWordMotion.characters(of: cells(row))
    }

    private func lastWrittenColumn(of row: Int) -> Int { line(row).last?.column ?? 0 }

    private func isBlankRow(_ row: Int) -> Bool { line(row).isEmpty }

    private var lastWrittenRow: Int {
        let last = max(rowCount - 1, 0)
        for row in stride(from: last, through: max(last - screenRows, 0), by: -1) where !isBlankRow(row) {
            return row
        }
        return last
    }

    private func textPoint(column: Int, row: Int) -> TerminalGridPoint {
        let clamped = min(max(row, 0), max(rowCount - 1, 0))
        return TerminalGridPoint(row: clamped, column: min(column, lastWrittenColumn(of: clamped)))
    }

    private func stepped(_ point: TerminalGridPoint, by delta: Int) -> TerminalGridPoint {
        let row = cells(point.row)
        let last = lastWrittenColumn(of: point.row)
        var column = point.column
        var steps = abs(delta)
        if delta < 0, column > last {
            column = last
            steps -= 1
        }
        for _ in 0..<steps {
            var next = column + (delta > 0 ? max(row.indices.contains(column) ? row[column].width : 1, 1) : -1)
            if delta < 0, row.indices.contains(next), row[next].width == 0 { next -= 1 }
            guard next >= 0, next <= last else { break }
            column = next
        }
        return TerminalGridPoint(row: point.row, column: column)
    }

    private func reveal() {
        guard let grid, let cursor else { return }
        let top = grid.viewportTop
        let bottom = top + screenRows - 1
        if cursor.row < top {
            surface?.scroll(.lines(cursor.row - top))
        } else if cursor.row > bottom {
            surface?.scroll(.lines(cursor.row - bottom))
        }
    }

    private func keepCursorInView() {
        guard let grid else { return }
        let top = grid.viewportTop
        let bottom = top + screenRows - 1
        guard let cursor else {
            seat(at: TerminalGridPoint(row: top, column: 0))
            return
        }
        guard cursor.row < top || cursor.row > bottom else { return }
        seat(at: textPoint(column: cursor.column, row: min(max(cursor.row, top), bottom)))
        applySelection()
    }

    /// Prompts stop it where shell integration marks them, found on the shell's row, the screen, or the walk.
    private func paragraphRow(from row: Int, delta: Int, times: Int) -> Int {
        guard let grid, delta != 0 else { return row }
        var integrated = hasPromptMarks(grid)
        var current = row
        for _ in 0..<times {
            let next = paragraphStop(from: current, delta: delta, integrated: &integrated)
            if next == current { break }
            current = next
        }
        return current
    }

    private func hasPromptMarks(_ grid: TerminalGrid) -> Bool {
        if let shell = grid.cursorPoint, grid.row(shell.row)?.prompt != TerminalGridRow.Prompt.none { return true }
        let top = grid.viewportTop
        return (top..<min(top + screenRows, grid.rowCount)).contains {
            grid.row($0)?.prompt != TerminalGridRow.Prompt.none
        }
    }

    private func paragraphStop(from row: Int, delta: Int, integrated: inout Bool) -> Int {
        guard let grid else { return row }
        let last = max(grid.rowCount - 1, 0)
        var next = row + delta
        var inBlock = false
        while next >= 0, next <= last, let candidate = grid.row(next) {
            if candidate.prompt != .none { integrated = true }
            if candidate.prompt == .start { return next }
            let blank = ScrollWordMotion.characters(of: candidate.cells).isEmpty
            if !integrated {
                if inBlock, blank { return next }
                if !blank { inBlock = true }
            }
            next += delta
        }
        return min(max(next, 0), last)
    }

    private func wordScreen(wide: Bool) -> ScrollWordMotion.Screen {
        ScrollWordMotion.Screen(lastRow: max(rowCount - 1, 0), wide: wide) { [weak self] row in
            self?.cells(row) ?? []
        }
    }

    private func viewportRow(_ place: ScrollKeymap.ViewportPlace, offset: Int) -> Int {
        let top = grid?.viewportTop ?? 0
        let bottom = max(min(lastWrittenRow, top + screenRows - 1), top)
        switch place {
        case .top: return min(top + offset, bottom)
        case .middle: return top + (bottom - top) / 2
        case .bottom: return max(bottom - offset, top)
        }
    }

    private func wordUnderCursor() -> String? {
        guard let cursor else { return nil }
        let text = line(cursor.row)
        guard let index = text.firstIndex(where: { $0.column == cursor.column }),
            ScrollWordMotion.classify(text[index].character) == .keyword
        else { return nil }
        var start = index
        while start > 0, ScrollWordMotion.classify(text[start - 1].character) == .keyword { start -= 1 }
        var end = index
        while end + 1 < text.count, ScrollWordMotion.classify(text[end + 1].character) == .keyword { end += 1 }
        return String(text[start...end].map(\.character))
    }

    private func openSelection(_ kind: ScrollSelection.Kind) {
        if var current = selection {
            guard current.kind != kind else { return closeSelection() }
            current.kind = kind
            selection = current
        } else {
            guard let cursor, let anchor = grid?.mark(cursor) else { return }
            selection = ScrollSelection(kind: kind, anchor: anchor)
        }
        applySelection()
        refreshCursor()
    }

    private func closeSelection() {
        releaseSelection()
        refreshCursor()
    }

    private func releaseSelection() {
        guard selection != nil else { return }
        selection = nil
        grid?.setSelection(nil)
    }

    private func selectionSpan() -> ClosedRange<TerminalGridPoint>? {
        guard let grid, let selection, let cursor else { return nil }
        guard let anchor = Self.point(of: selection.anchor) else { return nil }
        return ScrollSelection.span(selection.kind, from: anchor, to: cursor, rowCount: grid.rowCount) {
            grid.row($0)
        }
    }

    /// Drops the selection once the scrollback prunes its anchor.
    private func applySelection() {
        guard let grid, selection != nil else { return }
        guard let span = selectionSpan() else { return releaseSelection() }
        grid.setSelection(span)
    }

    private func yank() {
        guard let grid, let span = selectionSpan() else { return }
        guard let text = grid.text(from: span.lowerBound, to: span.upperBound) else {
            Log.warning("scroll mode: the surface declined a yank read", category: .panes)
            return
        }
        copy(text)
        releaseSelection()
        flash(span)
    }

    private func yankLines(_ times: Int) {
        guard let grid, let cursor else { return }
        let first = ScrollSelection.wrappedLines(
            from: cursor.row, through: cursor.row, rowCount: grid.rowCount, row: grid.row)
        var last = first.upperBound
        for _ in 1..<max(times, 1) where last + 1 < grid.rowCount {
            last =
                ScrollSelection.wrappedLines(
                    from: last + 1, through: last + 1, rowCount: grid.rowCount, row: grid.row
                ).upperBound
        }
        let columns = grid.row(last)?.cells.count ?? 1
        let start = TerminalGridPoint(row: first.lowerBound, column: 0)
        let span = start...TerminalGridPoint(row: last, column: max(columns - 1, 0))
        guard let text = grid.text(from: span.lowerBound, to: span.upperBound) else {
            Log.warning("scroll mode: the surface declined a yank read", category: .panes)
            return
        }
        copy(text)
        flash(span)
    }

    private func copy(_ text: String) {
        yankPasteboard.clearContents()
        yankPasteboard.setString(text, forType: .string)
    }

    @discardableResult
    private func page(_ fraction: Double) -> Bool {
        guard let grid, let cursor else { return true }
        let rows = screenRows
        let advance = Int((fraction * Double(rows)).rounded(.towardZero))
        guard advance != 0 else { return true }
        let target = min(max(cursor.row + advance, 0), max(lastWrittenRow, 0))
        let maxTop = max(grid.rowCount - rows, 0)
        let centered = min(max(target - rows / 2, 0), maxTop)
        let shift = centered - grid.viewportTop
        let taken = advance > 0 ? max(shift, 0) : min(shift, 0)
        if taken != 0 { surface?.scroll(.lines(taken)) }
        move(to: textPoint(column: cursor.column, row: target))
        return true
    }

    private func runFind(_ find: ScrollKeymap.Find, times: Int, isRepeat: Bool) {
        guard let cursor else { return }
        let text = line(cursor.row)
        let pastLastWritten = find.direction == .backward ? text.count : nil
        guard var index = text.firstIndex(where: { $0.column >= cursor.column }) ?? pastLastWritten else { return }
        let characters = text.map(\.character)
        for step in 0..<times {
            let skips = find.till && (isRepeat || step > 0)
            let from = skips ? index + (find.direction == .forward ? 1 : -1) : index
            guard let next = Self.findColumn(find, from: from, in: characters), text.indices.contains(next) else {
                return
            }
            index = next
        }
        move(to: TerminalGridPoint(row: cursor.row, column: text[index].column))
    }

    /// An index into `text`, one character per cell.
    static func findColumn(_ find: ScrollKeymap.Find, from column: Int, in text: [Character]) -> Int? {
        let stride = find.direction == .forward ? 1 : -1
        var index = column + stride
        while text.indices.contains(index) {
            if text[index] == find.character { return find.till ? index - stride : index }
            index += stride
        }
        return nil
    }

    private func flash(_ span: ClosedRange<TerminalGridPoint>) {
        cancelFlash()
        flashRange = span
        flashLevel = 1
        refreshCursor()
        guard !Motion.isReduceMotionEnabled() else {
            flashTimer = Timer.scheduledTimer(withTimeInterval: Motion.fadeDuration, repeats: false) {
                [weak self] _ in MainActor.assumeIsolated { self?.cancelFlash() }
            }
            return
        }
        let step = CGFloat(Self.flashFrame / Motion.fadeDuration)
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

    var isFlashingForTesting: Bool { flashLevel > 0 }
    var lastPositionForTesting: TerminalScrollPosition? { lastPosition }

    private static let flashFrame: TimeInterval = 1.0 / 60

    private func refreshCursor() {
        guard isActive, let surface else { return }
        let top = grid?.viewportTop ?? 0
        let rows = screenRows
        panel?.setScrollCursor(
            ScrollCursorView.State(
                cursor: cursorState(top: top, rows: rows),
                flash: flashRange.flatMap { Self.viewportRange(of: $0, top: top, rows: rows) },
                flashLevel: flashLevel)
        ) { [weak surface] in surface?.cellMetrics }
    }

    private func cursorState(top: Int, rows: Int) -> ScrollCursorView.Cursor? {
        guard let cursor, cursor.row >= top, cursor.row < top + rows else { return nil }
        let row = cells(cursor.row)
        let cell = row.indices.contains(cursor.column) ? row[cursor.column] : nil
        let width = cell?.width == 2 ? 2 : 1
        return ScrollCursorView.Cursor(
            row: cursor.row - top, columns: cursor.column...(cursor.column + width - 1),
            glyph: cell?.text ?? "",
            ink: surface?.backgroundOverride ?? Theme.current.terminal.background)
    }

    private static func viewportRange(
        of span: ClosedRange<TerminalGridPoint>, top: Int, rows: Int
    ) -> TerminalViewportRange? {
        let bottom = top + rows - 1
        guard span.upperBound.row >= top, span.lowerBound.row <= bottom else { return nil }
        let startsAbove = span.lowerBound.row < top
        let endsBelow = span.upperBound.row > bottom
        return TerminalViewportRange(
            startRow: max(span.lowerBound.row, top) - top,
            startColumn: startsAbove ? 0 : span.lowerBound.column,
            endRow: min(span.upperBound.row, bottom) - top,
            endColumn: endsBelow ? Int.max : span.upperBound.column)
    }

    private static func point(of mark: TerminalGridMark?) -> TerminalGridPoint? {
        guard case .at(let point) = mark?.place else { return nil }
        return point
    }

    private static func gridSize(of surface: TerminalSurface?) -> GridSize? {
        surface?.cellMetrics.map { GridSize(columns: $0.columns, rows: $0.rows) }
    }

    /// libghostty pins a viewport above the active area, so one pull holds the whole visit.
    private func holdViewport(against position: TerminalScrollPosition) -> Bool {
        guard position.linesBelow == 0, let last = lastPosition else { return false }
        let growth = position.total - last.total
        guard growth > 0, position.offset - last.offset == growth else { return false }
        holdsViewport = true
        surface?.scroll(.lines(-growth))
        return true
    }

    /// A resize changes the grid's size before its report, which is how a rewrap is told from output.
    func report(position: TerminalScrollPosition, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        let size = Self.gridSize(of: surface)
        let resized = lastGridSize != nil && size != lastGridSize
        lastGridSize = size
        if !resized, holdViewport(against: position) { return }
        if let last = lastPosition, position.offset != last.offset { holdsViewport = false }
        lastPosition = position
        if resized {
            if cursor == nil { keepCursorInView() }
            reveal()
            applySelection()
        } else {
            keepCursorInView()
        }
        if selection != nil, selectionSpan() == nil { releaseSelection() }
        refreshCursor()
    }
}
