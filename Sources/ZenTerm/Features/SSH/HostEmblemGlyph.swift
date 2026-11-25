// The mark a host's emblem settles into once its login has an answer.
enum HostEmblemGlyph: Equatable {
    case check
    case cross

    private static let checkRows = ["00000", "00001", "00010", "10100", "01000"]

    var cells: [Bool] {
        let side = HostSignature.side
        switch self {
        case .check:
            return Self.checkRows.flatMap { row in row.map { $0 == "1" } }
        case .cross:
            return (0..<side * side).map { cell in
                let row = cell / side
                let column = cell % side
                return row == column || row + column == side - 1
            }
        }
    }
}
