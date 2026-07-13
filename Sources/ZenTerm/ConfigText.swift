import Foundation

/// Shared text plumbing for the `key = value` config files (`config`, `workspaces`, and the
/// `float =` / `keybind =` sub-grammars). Every parser and the writer treat comments and quotes
/// identically, so the rules live here once instead of being re-copied per file.
enum ConfigText {
    /// The index where a comment begins: the first `#` that starts the line or follows whitespace
    /// and is not inside double quotes; nil if the line has none. A `#` inside quotes (e.g. a quoted
    /// float command) is not a comment. `stripComment` and `trailingComment` are the two halves of
    /// this one scan.
    static func commentStart(in line: String) -> String.Index? {
        var inQuotes = false
        var previousWasSpace = true  // start-of-line counts, so a leading `#` is a comment
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes, previousWasSpace { return index }
            previousWasSpace = character.isWhitespace
        }
        return nil
    }

    /// The line with any comment removed. Both whole-line (`# note`) and trailing
    /// (`cursor-style = bar   # note`) comments go; a `#` inside double quotes survives.
    static func stripComment(_ line: String) -> String {
        guard let start = commentStart(in: line) else { return line }
        return String(line[..<start])
    }

    /// A trailing `# comment` (including the `#`), or nil if the line has none — the inverse of
    /// `stripComment`, used to preserve an existing comment when rewriting an active line.
    static func trailingComment(of line: String) -> String? {
        guard let start = commentStart(in: line) else { return nil }
        return String(line[start...])
    }

    /// Strip one surrounding pair of double quotes, if present — so `"npm run dev"` and
    /// `npm run dev` are equivalent.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
