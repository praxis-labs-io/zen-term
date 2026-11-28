import Foundation

// Claude Code folds a paste over these budgets into pasted content, which it reads as the user's own material.
enum AgentPaste {
    static let maxLength = 800
    static let maxNewlines = 2
    static let rowsBelowNewlineBudget = 10

    static func pieces(of text: String, rows: Int?) -> [String] {
        let newlineBudget = max(1, min((rows ?? .max) - rowsBelowNewlineBudget, maxNewlines))
        var pieces: [String] = []
        var piece = ""
        var length = 0
        var newlines = 0
        for character in text {
            let size = character.utf16.count
            let newline = isNewline(character) ? 1 : 0
            if !piece.isEmpty, length + size > maxLength || newlines + newline > newlineBudget {
                pieces.append(piece)
                (piece, length, newlines) = ("", 0, 0)
            }
            piece.append(character)
            length += size
            newlines += newline
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }

    private static func isNewline(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
    }
}
