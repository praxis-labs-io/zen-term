import TerminalKit

// libghostty reports no output, so each check reads from a mark at the screen the last check read, down to the bottom.
final class OutputWatch {
    private struct Spot {
        let mark: TerminalGridMark
        let counted: Int
    }

    let needle: String
    private var spots: [Spot] = []

    init(needle: String, surface: TerminalSurface?) {
        self.needle = needle
        _ = sawNeedle(in: surface)
    }

    // Rows above the screen are settled, so the screen alone is read in one go and becomes the next check's baseline.
    func sawNeedle(in surface: TerminalSurface?) -> Bool {
        guard let surface, let grid = surface.grid, let metrics = surface.cellMetrics, grid.rowCount > 0,
            let screenTop = lineStart(grid, at: max(grid.rowCount - metrics.rows, 0))
        else { return false }
        let (start, counted) = baseline(screenTop: screenTop)
        let lastColumn = max(metrics.columns - 1, 0)
        guard let mark = grid.mark(TerminalGridPoint(row: max(screenTop, start), column: 0)),
            case .at(let from) = mark.place,
            let screen = grid.text(from: from, to: TerminalGridPoint(row: grid.rowCount - 1, column: lastColumn))
        else { return false }
        var settled = ""
        if from.row > start {
            guard
                let text = grid.text(
                    from: TerminalGridPoint(row: start, column: 0),
                    to: TerminalGridPoint(row: from.row - 1, column: lastColumn))
            else { return false }
            settled = text
        }
        spots = spots.filter { $0.mark.place == .aside } + [Spot(mark: mark, counted: count(screen))]
        return count(settled) + count(screen) > counted
    }

    // A mark on the screen not showing keeps its place for when that screen returns, and the showing one starts fresh.
    private func baseline(screenTop: Int) -> (row: Int, counted: Int) {
        guard !spots.isEmpty else { return (screenTop, .max) }
        for spot in spots {
            if case .at(let point) = spot.mark.place { return (point.row, spot.counted) }
        }
        if spots.contains(where: { $0.mark.place == .aside }) { return (0, 0) }
        return (0, spots.last?.counted ?? 0)
    }

    private func lineStart(_ grid: TerminalGrid, at row: Int) -> Int? {
        var row = row
        while row > 0 {
            guard let current = grid.row(row) else { return nil }
            guard current.continues else { break }
            row -= 1
        }
        return row
    }

    private func count(_ text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
