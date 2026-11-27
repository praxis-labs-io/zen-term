extension TerminalGrid {
    func text(lastLines count: Int) -> String? {
        guard count > 0 else { return nil }
        var top = rowCount
        var bottom: (row: Int, column: Int)?
        var lines = 0
        while top > 0, lines < count {
            guard let line = line(endingAt: top - 1) else { return nil }
            if bottom == nil, !line.isBlank { bottom = (top - 1, line.lastColumn) }
            if bottom != nil { lines += 1 }
            top = line.firstRow
        }
        guard let bottom else { return "" }
        guard
            let text = text(
                from: TerminalGridPoint(row: top, column: 0),
                to: TerminalGridPoint(row: bottom.row, column: bottom.column))
        else { return nil }
        var kept = text.components(separatedBy: "\n")
        while let last = kept.last, last.allSatisfy(\.isWhitespace) { kept.removeLast() }
        return kept.suffix(count).joined(separator: "\n")
    }

    private func line(endingAt lastRow: Int) -> (firstRow: Int, lastColumn: Int, isBlank: Bool)? {
        guard let last = row(lastRow) else { return nil }
        var firstRow = lastRow
        var current = last
        var isBlank = Self.isBlank(last)
        while current.continues, firstRow > 0 {
            firstRow -= 1
            guard let above = row(firstRow) else { return nil }
            isBlank = isBlank && Self.isBlank(above)
            current = above
        }
        return (firstRow, max(last.cells.count - 1, 0), isBlank)
    }

    private static func isBlank(_ row: TerminalGridRow) -> Bool {
        row.cells.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
    }
}
