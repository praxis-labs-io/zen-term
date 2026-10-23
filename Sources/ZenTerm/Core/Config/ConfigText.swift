import Foundation

// Comment and quote rules shared by every `key = value` config parser and the writer.
enum ConfigText {
    static func commentStart(in line: String) -> String.Index? {
        var inQuotes = false
        var previousWasSpace = true
        for index in line.indices {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == "#", !inQuotes, previousWasSpace { return index }
            previousWasSpace = character.isWhitespace
        }
        return nil
    }

    static func stripComment(_ line: String) -> String {
        guard let start = commentStart(in: line) else { return line }
        return String(line[..<start])
    }

    static func trailingComment(of line: String) -> String? {
        guard let start = commentStart(in: line) else { return nil }
        return String(line[start...])
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
