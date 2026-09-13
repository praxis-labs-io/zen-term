/// Vim's `w`, `b` and `e` over a viewport, where a word never spans a row break.
enum ScrollWordMotion {
    enum Motion: Equatable {
        case next
        case back
        case end

        func destination(from cell: ScrollCell, on screen: Screen) -> ScrollCell {
            switch self {
            case .next: return nextWordStart(from: cell, on: screen)
            case .back: return previousWordStart(from: cell, on: screen)
            case .end: return wordEnd(from: cell, on: screen)
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

    /// A class so each row is split once; re-splitting per step makes a long `w` quadratic.
    final class Screen {
        let lastRow: Int
        let wide: Bool
        private let reader: (Int) -> String
        private var rows: [Int: [Character]] = [:]

        init(lastRow: Int, wide: Bool = false, row: @escaping (Int) -> String) {
            self.lastRow = lastRow
            self.wide = wide
            self.reader = row
        }

        private func characters(_ row: Int) -> [Character] {
            if let known = rows[row] { return known }
            let built = Array(reader(row))
            rows[row] = built
            return built
        }

        func characterClass(at cell: ScrollCell) -> CharacterClass {
            let text = characters(cell.row)
            guard text.indices.contains(cell.column) else { return .blank }
            return classify(text[cell.column], wide: wide)
        }

        func forward(_ cell: ScrollCell) -> ScrollCell? {
            if cell.column + 1 < characters(cell.row).count {
                return ScrollCell(row: cell.row, column: cell.column + 1)
            }
            guard cell.row < lastRow else { return nil }
            return ScrollCell(row: cell.row + 1, column: 0)
        }

        func backward(_ cell: ScrollCell) -> ScrollCell? {
            if cell.column > 0 { return ScrollCell(row: cell.row, column: cell.column - 1) }
            guard cell.row > 0 else { return nil }
            return ScrollCell(row: cell.row - 1, column: max(characters(cell.row - 1).count - 1, 0))
        }
    }

    static func nextWordStart(from cell: ScrollCell, on screen: Screen) -> ScrollCell {
        var current = cell
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

    static func previousWordStart(from cell: ScrollCell, on screen: Screen) -> ScrollCell {
        guard var current = screen.backward(cell) else { return cell }
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

    static func wordEnd(from cell: ScrollCell, on screen: Screen) -> ScrollCell {
        guard var current = screen.forward(cell) else { return cell }
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
