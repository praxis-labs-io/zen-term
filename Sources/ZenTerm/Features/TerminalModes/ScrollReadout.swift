import TerminalKit

// What scroll mode says in the header's path slot: where the cursor is, what a selection covers, or what a copy took.
enum ScrollReadout: Equatable {
    case position(TerminalGridPoint)
    case characters(Int)
    case lines(Int)
    case copiedCharacters(Int)
    case copiedLines(Int)

    var text: String {
        switch self {
        case .position(let point): return "\(point.row + 1):\(point.column + 1)"
        case .characters(let count): return "\(count) \(Self.characters(count))"
        case .lines(let count): return "\(count) \(Self.lines(count))"
        case .copiedCharacters(let count): return "Copied \(count) \(Self.characters(count))"
        case .copiedLines(let count): return "Copied \(count) \(Self.lines(count))"
        }
    }

    var copied: ScrollReadout {
        switch self {
        case .characters(let count): return .copiedCharacters(count)
        case .lines(let count): return .copiedLines(count)
        default: return self
        }
    }

    private static func characters(_ count: Int) -> String { count == 1 ? "character" : "characters" }

    private static func lines(_ count: Int) -> String { count == 1 ? "line" : "lines" }

    static func selection(
        _ kind: ScrollSelection.Kind, span: ClosedRange<TerminalGridPoint>, cells: () -> [TerminalGridCell]
    ) -> ScrollReadout {
        let rows = span.upperBound.row - span.lowerBound.row + 1
        guard kind == .character, rows == 1 else { return .lines(rows) }
        let row = cells()
        let covered = span.lowerBound.column...span.upperBound.column
        return .characters(covered.count { !row.indices.contains($0) || row[$0].width != 0 })
    }
}
