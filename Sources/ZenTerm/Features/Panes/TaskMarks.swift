import TerminalKit

// Where each pane's last task or message sent with enter began, for `pane.read` with `since`. Main-thread only.
final class TaskMarks {
    enum Read: Equatable {
        case noTask
        case unreadable
        case text(String, truncated: Bool)
    }

    private var marks: [SurfaceID: TerminalGridMark] = [:]

    func mark(_ surface: SurfaceID, at terminal: TerminalSurface) {
        marks[surface] = terminal.grid.flatMap { grid in
            grid.cursorPoint.flatMap { grid.mark(TerminalGridPoint(row: $0.row, column: 0)) }
        }
    }

    func release(_ surface: SurfaceID) { marks[surface] = nil }

    // A mark the scrollback dropped reads from the oldest row, and one on the screen not showing reads that screen.
    func read(since surface: SurfaceID, in terminal: TerminalSurface) -> Read {
        guard let mark = marks[surface] else { return .noTask }
        guard let grid = terminal.grid, grid.rowCount > 0 else {
            return .unreadable
        }
        let start: TerminalGridPoint
        let truncated: Bool
        switch mark.place {
        case .at(let point): (start, truncated) = (point, false)
        case .gone: (start, truncated) = (TerminalGridPoint(row: 0, column: 0), true)
        case .aside:
            (start, truncated) = (TerminalGridPoint(row: grid.screenTop, column: 0), true)
        }
        guard let end = grid.lastCell(of: grid.rowCount - 1), let text = grid.text(from: start, to: end) else {
            return .unreadable
        }
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return .text(lines.joined(separator: "\n"), truncated: truncated)
    }
}
