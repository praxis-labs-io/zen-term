import Foundation

/// What a linewise selection in the diff pane resolves to: the text of the selected lines, and the
/// span of file line numbers they cover on each side. Pure over the rendered `DiffRow` list, so it
/// reads the same selection out of either layout (ZEN-227).
///
/// Sides matter because only the *new* side exists on disk. A reference an agent can act on has to
/// name new-side line numbers, so a selection that covers none (a run of deletions) carries
/// `anchorNewLine` instead: the new-side line the deletion follows.
struct DiffSelection: Equatable {
    /// The selected lines' text in view order, one entry per line. Hunk headers contribute nothing.
    let lines: [String]
    /// The first and last new-side line numbers the selection covers, or nil when it covers none.
    let newRange: ClosedRange<Int>?
    /// The first and last old-side line numbers the selection covers, or nil when it covers none.
    let oldRange: ClosedRange<Int>?
    /// The nearest new-side line number *above* the selection, for a selection with no new side of
    /// its own. Nil when nothing above it has one either (the file opens with a deletion).
    let anchorNewLine: Int?

    var isEmpty: Bool { lines.isEmpty }
    var codeText: String { lines.joined(separator: "\n") }

    /// Resolve `selected` (row indices into `rows`) into a selection. A row's text comes from its new
    /// side when it has one and its old side otherwise, so a removed line still yields its own text
    /// rather than the blank filler opposite it.
    static func make(rows: [DiffRow], selected: IndexSet) -> DiffSelection {
        var lines: [String] = []
        var newNumbers: [Int] = []
        var oldNumbers: [Int] = []

        for index in selected where rows.indices.contains(index) {
            guard let line = Self.line(at: index, in: rows) else { continue }  // a hunk header
            lines.append(line.text)
            if let new = line.new { newNumbers.append(new) }
            if let old = line.old { oldNumbers.append(old) }
        }

        return DiffSelection(
            lines: lines,
            newRange: Self.range(of: newNumbers),
            oldRange: Self.range(of: oldNumbers),
            anchorNewLine: newNumbers.isEmpty ? Self.anchorNewLine(above: selected.first, in: rows) : nil)
    }

    /// A row's identity across a re-render: the file line numbers it carries, on either side. Row
    /// *indices* can't play that part — the two layouts index differently, and a reload changes the
    /// content under them (ZEN-233).
    typealias LineNumbers = (old: Int?, new: Int?)

    /// The line numbers a row occupies, or nil for a hunk header or an out-of-range index. This pair
    /// is a row's identity *across* a layout change — the row indices differ between side-by-side and
    /// inline, so a cursor carried over a re-render is carried as this and re-found with `row(for:)`.
    static func lineNumbers(at index: Int, in rows: [DiffRow]) -> LineNumbers? {
        guard rows.indices.contains(index), let line = Self.line(at: index, in: rows) else { return nil }
        guard line.old != nil || line.new != nil else { return nil }
        return (line.old, line.new)
    }

    /// Find the row carrying `lineNumbers`. Matches on the new side first — that's the file on disk,
    /// and it's the side both layouts agree on for anything that isn't a deletion.
    static func row(for lineNumbers: LineNumbers, in rows: [DiffRow]) -> Int? {
        if let new = lineNumbers.new,
            let match = rows.indices.first(where: { Self.line(at: $0, in: rows)?.new == new })
        {
            return match
        }
        guard let old = lineNumbers.old else { return nil }
        return rows.indices.first { Self.line(at: $0, in: rows)?.old == old }
    }

    /// One row flattened to the fields a selection cares about, or nil for a hunk header.
    private static func line(at index: Int, in rows: [DiffRow]) -> (text: String, old: Int?, new: Int?)? {
        switch rows[index] {
        case .hunkHeader:
            return nil
        case .split(let left, let right):
            // The right cell is the new side (added or context), the left is the old side (removed or
            // context). A nil side is a filler that keeps the columns aligned and holds no line.
            guard let cell = right ?? left else { return nil }
            return (cell.text, left?.lineNumber, right?.lineNumber)
        case .unified(let text, _, let old, let new, _):
            return (text, old, new)
        }
    }

    private static func range(of numbers: [Int]) -> ClosedRange<Int>? {
        guard let low = numbers.min(), let high = numbers.max() else { return nil }
        return low...high
    }

    /// The closest new-side line number strictly above `start` — the line a pure deletion sits after.
    private static func anchorNewLine(above start: Int?, in rows: [DiffRow]) -> Int? {
        guard let start else { return nil }
        var index = min(start, rows.count) - 1
        while index >= 0 {
            if let new = Self.line(at: index, in: rows)?.new { return new }
            index -= 1
        }
        return nil
    }
}
