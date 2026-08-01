/// Vim's `w`, `b` and `e` over a terminal viewport.
///
/// A row's text ends where its characters do: `read_text` trims a row's trailing blanks, so the
/// columns past the last character are not cells to land on and stepping off the end of a row lands
/// on the start of the next.
///
/// **A word never spans a row break**, even where the classes line up, or a `w` from `two` in
/// `one two` runs clean past `three` on the row below.
enum ScrollWordMotion {
    enum Motion: Equatable {
        case next  // w
        case back  // b
        case end  // e

        func destination(from cell: ScrollCell, on screen: Screen) -> ScrollCell {
            switch self {
            case .next: return nextWordStart(from: cell, on: screen)
            case .back: return previousWordStart(from: cell, on: screen)
            case .end: return wordEnd(from: cell, on: screen)
            }
        }
    }

    /// A word is a run of one of the two non-blank classes, so `foo.bar` is three words: a class
    /// change starts one with no blank between.
    enum CharacterClass {
        case keyword
        case punctuation
        case blank
    }

    /// `iskeyword` at its default: letters, digits and underscore.
    static func classify(_ character: Character) -> CharacterClass {
        if character.isWhitespace { return .blank }
        if character.isLetter || character.isNumber || character == "_" { return .keyword }
        return .punctuation
    }

    /// The rows a motion walks. `row` answers `""` for anything unreadable, which behaves as blank.
    ///
    /// A class so it can hold each row's characters once. A `w` along a long row asks for a
    /// character per step, and re-splitting the string each time makes one keystroke quadratic.
    final class Screen {
        let lastRow: Int
        private let reader: (Int) -> String
        private var rows: [Int: [Character]] = [:]

        init(lastRow: Int, row: @escaping (Int) -> String) {
            self.lastRow = lastRow
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
            return classify(text[cell.column])
        }

        /// The next cell, or nil at the end of the screen.
        func forward(_ cell: ScrollCell) -> ScrollCell? {
            if cell.column + 1 < characters(cell.row).count {
                return ScrollCell(row: cell.row, column: cell.column + 1)
            }
            guard cell.row < lastRow else { return nil }
            return ScrollCell(row: cell.row + 1, column: 0)
        }

        /// The previous cell, or nil at the top of the screen.
        func backward(_ cell: ScrollCell) -> ScrollCell? {
            if cell.column > 0 { return ScrollCell(row: cell.row, column: cell.column - 1) }
            guard cell.row > 0 else { return nil }
            return ScrollCell(row: cell.row - 1, column: max(characters(cell.row - 1).count - 1, 0))
        }
    }

    /// `w`: the start of the next word. Every motion here parks on the last cell it reached rather
    /// than failing at the edge of the screen.
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

    /// `b`: the start of this word, or of the previous one when already on it.
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

    /// `e`: the end of this word, or of the next one when already on it.
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
