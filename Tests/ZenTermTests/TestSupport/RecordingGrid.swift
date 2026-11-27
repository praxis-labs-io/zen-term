import TerminalKit

// `RecordingSurface`'s scrollback and rows as a grid; a row wraps only when listed in `wrappingRows`.
final class RecordingGrid: TerminalGrid {
    private unowned let surface: RecordingSurface
    private(set) var liveMarks = 0

    var wrappingRows: Set<Int> = []
    var widthBeforeResize: Int?

    init(surface: RecordingSurface) {
        self.surface = surface
    }

    private var lines: [String] { surface.scrollback + surface.rows }

    private var columns: Int { widthBeforeResize ?? surface.cellMetrics?.columns ?? 80 }

    var rowCount: Int { lines.count }
    var viewportTop: Int { surface.scrollback.count }
    var cursorPoint: TerminalGridPoint? {
        let written = lines.lastIndex { !$0.isEmpty }.map { $0 + 1 } ?? 0
        return TerminalGridPoint(row: min(written, max(rowCount - 1, 0)), column: 0)
    }
    var selectionBounds: ClosedRange<TerminalGridPoint>? { nil }

    func row(_ index: Int) -> TerminalGridRow? {
        let lines = lines
        guard !surface.screenIsUnreadable, lines.indices.contains(index) else { return nil }
        var cells: [TerminalGridCell] = []
        for character in lines[index] {
            let width = RecordingSurface.width(character)
            cells.append(
                TerminalGridCell(
                    text: character == RecordingSurface.unwritten ? "" : String(character), width: width,
                    kind: .output))
            if width == 2 { cells.append(TerminalGridCell(text: "", width: 0, kind: .output)) }
        }
        cells += Array(
            repeating: TerminalGridCell(text: "", width: 1, kind: .output), count: max(columns - cells.count, 0))
        return TerminalGridRow(
            cells: cells, wraps: wrappingRows.contains(index), continues: wrappingRows.contains(index - 1),
            prompt: .none)
    }

    func text(from start: TerminalGridPoint, to end: TerminalGridPoint) -> String? {
        let first = min(start, end)
        let last = max(start, end)
        var text = ""
        guard first.column < columns, last.column < columns else { return nil }
        for index in first.row...last.row {
            guard let row = row(index) else { return nil }
            let from = index == first.row ? first.column : 0
            let through = min(index == last.row ? last.column : Int.max, row.cells.count - 1)
            let cells = from <= through ? Array(row.cells[from...through]) : []
            let written = cells.lastIndex { !$0.text.isEmpty }.map { cells[...$0] } ?? []
            text += written.filter { $0.width > 0 }.map { $0.text.isEmpty ? " " : $0.text }.joined()
            if index < last.row, !row.wraps { text += "\n" }
        }
        return text
    }

    func mark(_ point: TerminalGridPoint) -> TerminalGridMark? {
        guard lines.indices.contains(point.row), point.column < columns else { return nil }
        liveMarks += 1
        return TerminalGridMark(read: { .at(point) }, release: { [weak self] in self?.liveMarks -= 1 })
    }

    func setSelection(_ range: ClosedRange<TerminalGridPoint>?) {}
}
