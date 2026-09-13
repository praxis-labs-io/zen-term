import AppKit
import AppLog
import TerminalKit

@MainActor
final class ScrollModeController {
    private(set) var isActive = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: TerminalModeHost?
    private var pending = ScrollKeymap.Pending()

    private(set) var cursor = ScrollCell.origin

    var cursorRow: Int { cursor.row }

    private(set) var selection: ScrollSelection?

    var yankPasteboard: NSPasteboard = .general

    private var rowCache: [Int: String] = [:]

    private var rawCache: [Int: String] = [:]

    /// Each miss costs a dozen renderer-mutex reads, and the yank pulse refreshes the band sixty times a second.
    private var cellCache: [Int: [Int: ClosedRange<Int>]] = [:]

    private var lastPosition: TerminalScrollPosition?

    private var flashRange: TerminalViewportRange?
    private var flashLevel: CGFloat = 0
    private var flashTimer: Timer?

    var onActiveChanged: ((Bool) -> Void)?

    var onSearchWord: ((String) -> Void)?

    func begin(surface: AnyObject & TerminalSurface, panel: TerminalModeHost) {
        guard !isActive else { return }
        self.surface = surface
        self.panel = panel
        pending = .init()
        selection = nil
        lastPosition = nil
        pendingAnchor = nil
        pendingSelectionAnchor = nil
        cursorLine = nil
        holdsViewport = false
        reflowArmedAt = nil
        cursor = .origin
        isActive = true
        invalidateRows()
        Log.info("scroll mode entered", category: .panes)
        let entry = Self.entryCell(of: surface)
        cursor = ScrollCell(row: entry.row, column: offset(ofCell: entry.column, on: entry.row))
        let entryText = rowText(cursor.row)
        cursorLine = Self.isBlank(entryText) ? nil : entryText
        updateHeader()
        panel.layoutSubtreeIfNeeded()
        refreshCursor(remembersLine: false)
        onActiveChanged?(true)
    }

    /// Idempotent: every teardown trigger calls it without checking whether another got there first.
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
        pendingSelectionAnchor = nil
        cursorLine = nil
        invalidateRows()
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

    static func entryCell(of surface: TerminalSurface) -> ScrollCell {
        if let origin = surface.selectionOrigin {
            return ScrollCell(row: origin.row, column: origin.column)
        }
        return ScrollCell(row: entryRow(of: surface), column: 0)
    }

    static func entryRow(of surface: TerminalSurface) -> Int {
        let last = max((surface.cellMetrics?.rows ?? 1) - 1, 0)
        for row in stride(from: last, through: 0, by: -1)
        where !isBlank(surface.text(viewportRow: row)) {
            return row
        }
        return last
    }

    func refreshGeometry() {
        guard isActive else { return }
        let armedAt = now()
        pendingAnchor = cursorLine.map { (line: $0, armedAt: armedAt) }
        reflowArmedAt = armedAt
        armSelectionAnchor()
        invalidateRows()
        refreshCursor(remembersLine: false)
    }

    private func armSelectionAnchor() {
        guard let selection else { return }
        guard let line = selection.anchorLine, pendingAnchor != nil else { return releaseSelection() }
        pendingSelectionAnchor = (line: line, anchorWasFirst: selection.anchor.row <= cursor.row)
    }

    private var pendingSelectionAnchor: (line: String, anchorWasFirst: Bool)?

    func reportReflow(from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        refreshGeometry()
    }

    private var pendingAnchor: (line: String, armedAt: ContinuousClock.Instant)?

    /// Captured on every placement because a reflow is announced only after the grid has changed.
    private var cursorLine: String?

    /// libghostty reports a scrollbar only when it changes, so a reflow that rewraps nothing never answers.
    private static let anchorLifetime: Duration = .seconds(1)

    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    private func reanchor(to line: String) {
        guard let best = row(matching: line, near: cursor.row) else { return }
        move(to: ScrollCell(row: best, column: cursor.column))
    }

    private func row(matching line: String, near origin: Int) -> Int? {
        exactRow(of: line, near: origin) ?? fragmentRow(of: line, near: origin)
            ?? containedRow(of: line, near: origin)
    }

    /// Nearest match wins: a prompt string repeats down the viewport.
    private func exactRow(of line: String, near origin: Int) -> Int? {
        let here = min(max(origin, 0), lastRow)
        if rowText(here) == line { return here }
        for distance in 1...max(lastRow, 1) {
            for row in [here - distance, here + distance] where row >= 0 && row <= lastRow {
                if rowText(row) == line { return row }
            }
        }
        return nil
    }

    private func fragmentRow(of line: String, near origin: Int) -> Int? {
        bestRow(matching: line, near: origin) { text, line in
            text.hasPrefix(line) || line.hasPrefix(text)
        }
    }

    private func containedRow(of line: String, near origin: Int) -> Int? {
        bestRow(matching: line, near: origin) { text, line in
            text.contains(line) || line.contains(text)
        }
    }

    private func bestRow(
        matching line: String, near origin: Int, overlaps: (String, String) -> Bool
    ) -> Int? {
        var best: (row: Int, shared: Int)?
        for row in 0...lastRow {
            let text = rowText(row)
            guard overlaps(text, line) else { continue }
            let shared = min(text.count, line.count)
            guard shared >= Self.minimumFragmentMatch else { continue }
            let isBetter =
                best.map {
                    shared > $0.shared
                        || (shared == $0.shared && abs(row - origin) < abs($0.row - origin))
                } ?? true
            if isBetter { best = (row, shared) }
        }
        return best?.row
    }

    /// Below this, a shared prompt sigil would count as the same line.
    private static let minimumFragmentMatch = 8

    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    func land(on cell: ScrollCell) {
        guard isActive else { return }
        invalidateRows()
        releaseSelection()
        pendingAnchor = nil
        move(to: cell)
    }

    /// Declines unmapped ⌘ and ⌥ chords: `KeyInterceptor` runs before menu key equivalents resolve.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        if let pendingSpan = pendingSelectionAnchor {
            pendingSelectionAnchor = nil
            invalidateRows()
            if let pendingCursor = pendingAnchor {
                pendingAnchor = nil
                reanchor(to: pendingCursor.line)
            }
            reanchorSelection(pendingSpan)
        }
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
        pendingAnchor = nil
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
            if selection != nil { closeSelection() } else { end() }
        case .step(let delta):
            step(delta)
        case .paragraph(let delta, let times):
            var row = cursor.row
            for _ in 0..<times {
                let next = paragraphRow(from: row, delta: delta)
                if next == row { break }
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
                if next == destination { break }
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
            if case .pageFraction(let fraction) = move { return page(fraction) }
            switch move {
            case .top: cursor = ScrollCell(row: 0, column: cursor.column)
            case .bottom: cursor = ScrollCell(row: lastRow, column: cursor.column)
            default: break
            }
            surface?.scroll(move)
            cursorLine = nil
            refreshCursor(remembersLine: false)
            invalidateRows()
        }
        return true
    }

    private func step(_ delta: Int) {
        let target = cursor.row + delta
        let landed = min(max(target, 0), lastRow)
        if landed != cursor.row { move(to: ScrollCell(row: landed, column: cursor.column)) }
        let overshoot = target - landed
        guard overshoot != 0 else { return }
        surface?.scroll(.lines(overshoot))
        cursorLine = nil
        refreshCursor(remembersLine: false)
        invalidateRows()
    }

    private func move(to cell: ScrollCell) {
        let row = min(max(cell.row, 0), lastRow)
        cursor = ScrollCell(row: row, column: min(max(cell.column, 0), lastColumn(of: row)))
        refreshCursor()
        if selection != nil { updateHeader() }
    }

    private var lastRow: Int { max((surface?.cellMetrics?.rows ?? 1) - 1, 0) }

    private func lastColumn(of row: Int) -> Int { max(rowText(row).count - 1, 0) }

    private func selectionRange() -> TerminalViewportRange? {
        guard pendingSelectionAnchor == nil else { return nil }
        return paintedSelectionRange()
    }

    private func paintedSelectionRange() -> TerminalViewportRange? {
        guard let selection, let columns = surface?.cellMetrics?.columns else { return nil }
        return selection.range(to: cursor, columns: columns) { self.cells(of: $0) }
    }

    private func cells(of cell: ScrollCell) -> ClosedRange<Int> {
        let text = rowText(cell.row)
        let offset = min(max(cell.column, 0), max(text.count - 1, 0))
        guard !text.allSatisfy(\.isASCII) else { return offset...offset }
        if let known = cellCache[cell.row]?[offset] { return known }
        let first = cellStart(ofOffset: offset, on: cell.row)
        let isWide = self.offset(ofCell: first + 1, on: cell.row) == offset
        let span = first...(isWide ? first + 1 : first)
        cellCache[cell.row, default: [:]][offset] = span
        return span
    }

    private func offset(ofCell cell: Int, on row: Int) -> Int {
        guard cell > 0, let surface, let columns = surface.cellMetrics?.columns, cell < columns
        else { return max(cell, 0) }
        let rest = surface.text(
            in: TerminalViewportRange(
                startRow: row, startColumn: cell, endRow: row, endColumn: columns - 1))
        return max(rawRow(row).count - (rest?.count ?? 0), 0)
    }

    /// Searched from the right because a read drops a trailing run of never-written cells.
    private func cellStart(ofOffset offset: Int, on row: Int) -> Int {
        guard offset > 0 else { return 0 }
        guard let surface, let columns = surface.cellMetrics?.columns, columns > 0 else {
            return offset
        }
        let total = rawRow(row).count
        var low = 0
        var high = columns
        while low < high {
            let mid = (low + high) / 2
            let rest = surface.text(
                in: TerminalViewportRange(
                    startRow: row, startColumn: mid, endRow: row, endColumn: columns - 1))
            if total - (rest?.count ?? 0) >= offset { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Blank-line based: `jump_to_prompt` cannot reach on-screen prompts, and the C API exposes no prompt marks.
    private func paragraphRow(from row: Int, delta: Int) -> Int {
        guard surface != nil, delta != 0 else { return row }
        let limit = lastRow
        var next = row + delta
        while next >= 0 && next <= limit && isBlankRow(next) { next += delta }
        while next >= 0 && next <= limit && !isBlankRow(next) { next += delta }
        return min(max(next, 0), limit)
    }

    private func screen(wide: Bool = false) -> ScrollWordMotion.Screen {
        ScrollWordMotion.Screen(lastRow: lastRow, wide: wide) { [weak self] row in
            self?.rowText(row) ?? ""
        }
    }

    private func firstNonBlankColumn(of row: Int) -> Int {
        Array(rowText(row)).firstIndex { !$0.isWhitespace } ?? 0
    }

    private func viewportRow(_ place: ScrollKeymap.ViewportPlace, offset: Int) -> Int {
        let bottom = lastWrittenRow
        switch place {
        case .top: return min(offset, bottom)
        case .middle: return bottom / 2
        case .bottom: return max(bottom - offset, 0)
        }
    }

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

    /// Cached for one keystroke only, since nothing announces a repaint.
    private func rowText(_ row: Int) -> String {
        if let known = rowCache[row] { return known }
        var text = rawRow(row)
        while let last = text.last, last.isWhitespace { text.removeLast() }
        rowCache[row] = text
        return text
    }

    private func rawRow(_ row: Int) -> String {
        if let known = rawCache[row] { return known }
        let text = surface?.text(viewportRow: row) ?? ""
        rawCache[row] = text
        return text
    }

    private func isBlankRow(_ row: Int) -> Bool { Self.isBlank(rowText(row)) }

    private func invalidateRows() {
        rowCache.removeAll(keepingCapacity: true)
        rawCache.removeAll(keepingCapacity: true)
        cellCache.removeAll(keepingCapacity: true)
    }

    static func isBlank(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.allSatisfy(\.isWhitespace)
    }

    private func openSelection(_ kind: ScrollSelection.Kind) {
        if var current = selection {
            guard current.kind != kind else { return closeSelection() }
            current.kind = kind
            selection = current
        } else {
            let text = rowText(cursor.row)
            selection = ScrollSelection(
                kind: kind, anchor: cursor, anchorLine: Self.isBlank(text) ? nil : text)
        }
        updateHeader()
        refreshCursor()
    }

    private func closeSelection() {
        selection = nil
        pendingSelectionAnchor = nil
        updateHeader()
        refreshCursor()
    }

    private func moveAnchor(toRow row: Int?) {
        guard var current = selection else { return }
        guard let row, row >= 0, row <= lastRow else { return releaseSelection() }
        current.anchor = ScrollCell(row: row, column: current.anchor.column)
        selection = current
        pendingSelectionAnchor = nil
        refreshCursor(remembersLine: false)
        updateHeader()
    }

    private func shiftSelection(byRows rows: Int) {
        guard let current = selection else { return }
        moveAnchor(toRow: current.anchor.row + rows)
    }

    private func reanchorSelection(_ pending: (line: String, anchorWasFirst: Bool)) {
        guard let current = selection else { return }
        guard let row = row(matching: pending.line, near: current.anchor.row) else {
            return releaseSelection()
        }
        guard pending.anchorWasFirst == (row <= cursor.row) else { return releaseSelection() }
        moveAnchor(toRow: row)
    }

    private func releaseSelection() {
        pendingSelectionAnchor = nil
        guard selection != nil else { return }
        selection = nil
        updateHeader()
        refreshCursor(remembersLine: false)
    }

    /// Chrome-owned, so libghostty's search-the-selection, which reads `Screen.selection`, cannot see it.
    var selectedText: String? {
        guard let surface, let range = selectionRange() else { return nil }
        let text = surface.text(in: range)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private func yank() {
        guard let surface, let range = selectionRange() else { return }
        guard let text = surface.text(in: range) else {
            Log.warning("scroll mode: the surface declined a yank read", category: .panes)
            return
        }
        yankPasteboard.clearContents()
        yankPasteboard.setString(text, forType: .string)
        self.selection = nil
        pendingSelectionAnchor = nil
        updateHeader()
        flash(range)
    }

    private var lastWrittenRow: Int {
        let last = lastRow
        for row in stride(from: last, through: 0, by: -1) where !Self.isBlank(rowText(row)) {
            return row
        }
        return last
    }

    @discardableResult
    private func page(_ fraction: Double) -> Bool {
        let rows = max(surface?.cellMetrics?.rows ?? 1, 1)
        let advance = Int((fraction * Double(rows)).rounded(.towardZero))
        guard advance != 0 else { return true }
        let down = advance > 0
        let want = cursor.row + advance
        let room = (down ? lastPosition?.linesBelow : lastPosition?.offset) ?? .max
        let ideal = want - lastRow / 2
        let taken = down ? min(max(ideal, 0), room) : max(min(ideal, 0), -room)
        if taken != 0 { surface?.scroll(.lines(taken)) }
        clampsToWrittenRows = down && taken == room
        let landed = down ? min(want - taken, lastWrittenRow) : want - taken
        cursor = ScrollCell(row: min(max(landed, 0), lastRow), column: cursor.column)
        cursorLine = nil
        refreshCursor(remembersLine: false)
        invalidateRows()
        return true
    }

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

    private var clampsToWrittenRows = false

    private var lastFind: ScrollKeymap.Find?

    private func runFind(_ find: ScrollKeymap.Find, times: Int, isRepeat: Bool) {
        let text = Array(rowText(cursor.row))
        var column = cursor.column
        for step in 0..<times {
            let skips = find.till && (isRepeat || step > 0)
            let from = skips ? column + (find.direction == .forward ? 1 : -1) : column
            guard let next = Self.findColumn(find, from: from, in: text) else { return }
            column = next
        }
        move(to: ScrollCell(row: cursor.row, column: column))
    }

    static func findColumn(_ find: ScrollKeymap.Find, from column: Int, in text: [Character]) -> Int? {
        let stride = find.direction == .forward ? 1 : -1
        var index = column + stride
        while text.indices.contains(index) {
            if text[index] == find.character { return find.till ? index - stride : index }
            index += stride
        }
        return nil
    }

    private func flash(_ range: TerminalViewportRange) {
        cancelFlash()
        flashRange = range
        flashLevel = 1
        refreshCursor()
        guard !Motion.isReduceMotionEnabled() else {
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

    var isFlashingForTesting: Bool { flashLevel > 0 }

    private static let flashDuration: TimeInterval = 0.22
    private static let flashFrame: TimeInterval = 1.0 / 60

    private func refreshCursor(remembersLine: Bool = true) {
        guard isActive, let surface else { return }
        let row = min(cursor.row, lastRow)
        let text = rowText(row)
        cursor = ScrollCell(row: row, column: min(cursor.column, max(text.count - 1, 0)))
        if remembersLine { cursorLine = Self.isBlank(text) ? nil : text }
        panel?.setScrollCursor(
            ScrollCursorView.State(
                cursorRow: cursor.row,
                cursorCells: cells(of: cursor),
                selection: paintedSelectionRange(),
                flash: flashRange,
                flashLevel: flashLevel)
        ) { [weak surface] in surface?.cellMetrics }
    }

    private var holdsViewport = false

    /// libghostty pins a viewport above the active area, so one pull holds the whole visit.
    private func holdViewport(against position: TerminalScrollPosition) -> Bool {
        guard !awaitsReflow, position.linesBelow == 0, let last = lastPosition else { return false }
        let growth = position.total - last.total
        guard growth > 0, position.offset - last.offset == growth else { return false }
        holdsViewport = true
        surface?.scroll(.lines(-growth))
        return true
    }

    private var reflowArmedAt: ContinuousClock.Instant?

    private var awaitsReflow: Bool {
        guard let armed = reflowArmedAt else { return false }
        return armed.duration(to: now()) <= Self.anchorLifetime
    }

    func report(position: TerminalScrollPosition, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        invalidateRows()
        if holdViewport(against: position) { return }
        let isReflow = awaitsReflow
        reflowArmedAt = nil
        if let last = lastPosition, position.offset != last.offset {
            if !isReflow, pendingSelectionAnchor == nil {
                shiftSelection(byRows: last.offset - position.offset)
            }
            holdsViewport = false
        }
        lastPosition = position
        if let pending = pendingAnchor {
            pendingAnchor = nil
            if pending.armedAt.duration(to: now()) <= Self.anchorLifetime {
                reanchor(to: pending.line)
            }
        }
        if let pending = pendingSelectionAnchor {
            pendingSelectionAnchor = nil
            if isReflow { reanchorSelection(pending) } else { releaseSelection() }
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

    static func headerTitle(_ position: TerminalScrollPosition?) -> String {
        guard let position else { return "Scroll" }
        let below = position.linesBelow
        if below == 0 { return "Scroll: at bottom" }
        return "Scroll: \(groupedCount(below)) below"
    }

    static func visualTitle(kind: ScrollSelection.Kind, rows: Int) -> String {
        switch kind {
        case .character: return "Visual"
        case .line: return "Visual: \(groupedCount(rows)) \(rows == 1 ? "line" : "lines")"
        }
    }

    static func groupedCount(_ value: Int) -> String {
        lineCount.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let lineCount: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
