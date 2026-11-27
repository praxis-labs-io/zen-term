import Foundation
import ObjectiveC
import TerminalKit

// RecordingSurface's scrollback and rows as a grid. A row never wraps, and a mark keeps its row index.
final class RecordingSurfaceGrid: TerminalGrid {
    private unowned let surface: RecordingSurface
    private(set) var liveMarks = 0

    init(surface: RecordingSurface) {
        self.surface = surface
    }

    private var lines: [String] { surface.scrollback + surface.rows }

    private var columns: Int { surface.cellMetrics?.columns ?? 80 }

    var rowCount: Int { lines.count }
    var viewportTop: Int { surface.scrollback.count }
    var cursorPoint: TerminalGridPoint? { nil }
    var selectionBounds: ClosedRange<TerminalGridPoint>? { nil }

    func row(_ index: Int) -> TerminalGridRow? {
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
        return TerminalGridRow(cells: cells, wraps: false, continues: false, prompt: .none)
    }

    func text(from start: TerminalGridPoint, to end: TerminalGridPoint) -> String? {
        var lines: [String] = []
        for index in start.row...end.row {
            guard let row = row(index) else { return nil }
            let from = index == start.row ? start.column : 0
            let through = min(index == end.row ? end.column : Int.max, row.cells.count - 1)
            let cells = from <= through ? Array(row.cells[from...through]) : []
            let written = cells.lastIndex { !$0.text.isEmpty }.map { cells[...$0] } ?? []
            lines.append(written.filter { $0.width > 0 }.map { $0.text.isEmpty ? " " : $0.text }.joined())
        }
        return lines.joined(separator: "\n")
    }

    func mark(_ point: TerminalGridPoint) -> TerminalGridMark? {
        guard lines.indices.contains(point.row) else { return nil }
        liveMarks += 1
        return TerminalGridMark(read: { .at(point) }, release: { [weak self] in self?.liveMarks -= 1 })
    }

    func setSelection(_ range: ClosedRange<TerminalGridPoint>?) {}
}

private var gridKey: UInt8 = 0

extension RecordingSurface {
    var grid: TerminalGrid? { isStarted && !terminated ? recordingGrid : nil }

    var recordingGrid: RecordingSurfaceGrid {
        if let grid = objc_getAssociatedObject(self, &gridKey) as? RecordingSurfaceGrid { return grid }
        let grid = RecordingSurfaceGrid(surface: self)
        objc_setAssociatedObject(self, &gridKey, grid, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return grid
    }
}
