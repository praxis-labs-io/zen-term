import TerminalKit

/// Vim's `w`, `b` and `e` over grid cells, where a word never spans a row break and a wide character is one step.
enum ScrollWordMotion {
    enum Motion: Equatable {
        case next
        case back
        case end

        func destination(from point: TerminalGridPoint, on screen: Screen) -> TerminalGridPoint {
            switch self {
            case .next: return nextWordStart(from: point, on: screen)
            case .back: return previousWordStart(from: point, on: screen)
            case .end: return wordEnd(from: point, on: screen)
            }
        }
    }

    enum CharacterClass {
        case keyword
        case punctuation
        case blank
    }

    static func classify(_ character: Character, wide: Bool = false) -> CharacterClass {
        if character.isWhitespace { return .blank }
        if wide { return .keyword }
        if character.isLetter || character.isNumber || character == "_" { return .keyword }
        return .punctuation
    }

    static func characters(of cells: [TerminalGridCell]) -> [(column: Int, character: Character)] {
        var line: [(column: Int, character: Character)] = []
        for (column, cell) in cells.enumerated() where cell.width > 0 {
            line.append((column, cell.text.first ?? " "))
        }
        while let last = line.last, last.character.isWhitespace { line.removeLast() }
        return line
    }

    /// A class so each row is read once; re-reading per step makes a long `w` quadratic.
    final class Screen {
        let lastRow: Int
        let wide: Bool
        private let reader: (Int) -> [TerminalGridCell]
        private var rows: [Int: [(column: Int, character: Character)]] = [:]

        init(lastRow: Int, wide: Bool = false, row: @escaping (Int) -> [TerminalGridCell]) {
            self.lastRow = lastRow
            self.wide = wide
            self.reader = row
        }

        func line(_ row: Int) -> [(column: Int, character: Character)] {
            if let known = rows[row] { return known }
            let built = ScrollWordMotion.characters(of: reader(row))
            rows[row] = built
            return built
        }

        func characterClass(at point: TerminalGridPoint) -> CharacterClass {
            guard let found = line(point.row).first(where: { $0.column == point.column }) else { return .blank }
            return classify(found.character, wide: wide)
        }

        func forward(_ point: TerminalGridPoint) -> TerminalGridPoint? {
            if let next = line(point.row).first(where: { $0.column > point.column }) {
                return TerminalGridPoint(row: point.row, column: next.column)
            }
            guard point.row < lastRow else { return nil }
            return TerminalGridPoint(row: point.row + 1, column: line(point.row + 1).first?.column ?? 0)
        }

        func backward(_ point: TerminalGridPoint) -> TerminalGridPoint? {
            if let previous = line(point.row).last(where: { $0.column < point.column }) {
                return TerminalGridPoint(row: point.row, column: previous.column)
            }
            guard point.row > 0 else { return nil }
            return TerminalGridPoint(row: point.row - 1, column: line(point.row - 1).last?.column ?? 0)
        }
    }

    static func nextWordStart(from point: TerminalGridPoint, on screen: Screen) -> TerminalGridPoint {
        var current = point
        let opening = screen.characterClass(at: current)
        if opening != .blank {
            while let next = screen.forward(current), next.row == current.row,
                screen.characterClass(at: next) == opening
            {
                current = next
            }
        }
        guard let afterWord = screen.forward(current) else { return current }
        current = afterWord
        while screen.characterClass(at: current) == .blank {
            guard let next = screen.forward(current) else { return current }
            current = next
        }
        return current
    }

    static func previousWordStart(from point: TerminalGridPoint, on screen: Screen) -> TerminalGridPoint {
        guard var current = screen.backward(point) else { return point }
        while screen.characterClass(at: current) == .blank {
            guard let previous = screen.backward(current) else { return current }
            current = previous
        }
        let run = screen.characterClass(at: current)
        while let previous = screen.backward(current), previous.row == current.row,
            screen.characterClass(at: previous) == run
        {
            current = previous
        }
        return current
    }

    static func wordEnd(from point: TerminalGridPoint, on screen: Screen) -> TerminalGridPoint {
        guard var current = screen.forward(point) else { return point }
        while screen.characterClass(at: current) == .blank {
            guard let next = screen.forward(current) else { return current }
            current = next
        }
        let run = screen.characterClass(at: current)
        while let next = screen.forward(current), next.row == current.row,
            screen.characterClass(at: next) == run
        {
            current = next
        }
        return current
    }
}
