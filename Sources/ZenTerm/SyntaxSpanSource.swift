import Foundation

/// Syntax spans for one file's two sides, keyed by 1-based file line number. The old side is keyed by
/// a line's `oldLineNumber`, the new side by its `newLineNumber`; a diff row looks up whichever side
/// it sits on. This is the shape the row transforms consume — position-keyed rather than text-keyed —
/// because the real engine (ZEN-239) parses each whole-file blob and maps token byte ranges back onto
/// file line numbers; the placeholder produces the same shape from line text.
struct DiffFileSpans: Equatable {
    let old: [Int: [TokenSpan]]
    let new: [Int: [TokenSpan]]

    func old(_ line: Int?) -> [TokenSpan]? { line.flatMap { old[$0] } }
    func new(_ line: Int?) -> [TokenSpan]? { line.flatMap { new[$0] } }
}

/// Produces syntax spans for a file's lines. ZEN-238 ships the `PlaceholderSpanSource`; ZEN-239
/// swaps in the tree-sitter `DiffHighlighter` behind this same seam, so the render and model layers
/// don't change when real highlighting arrives.
protocol SyntaxSpanSource {
    func spans(for file: FileDiff) -> DiffFileSpans?
}

/// A deliberately crude stand-in (ZEN-238): tokenizes each line on word boundaries and tags a small
/// set of common keywords and bare integers, so the attributed render path runs end to end before the
/// tree-sitter engine replaces it. Language-agnostic and not meant to highlight correctly — it exists
/// to prove the plumbing and to be unit-testable.
struct PlaceholderSpanSource: SyntaxSpanSource {
    private static let keywords: Set<String> = [
        "let", "var", "func", "if", "else", "guard", "return", "for", "while", "switch", "case",
        "struct", "enum", "class", "protocol", "extension", "import", "public", "private", "static",
        "self", "nil", "true", "false",
    ]

    func spans(for file: FileDiff) -> DiffFileSpans? {
        var old: [Int: [TokenSpan]] = [:]
        var new: [Int: [TokenSpan]] = [:]
        for hunk in file.hunks {
            for line in hunk.lines {
                let spans = Self.tokenize(line.text)
                guard !spans.isEmpty else { continue }
                if let number = line.oldLineNumber { old[number] = spans }
                if let number = line.newLineNumber { new[number] = spans }
            }
        }
        return DiffFileSpans(old: old, new: new)
    }

    /// Word runs (ASCII letters, digits, `_`) scanned in UTF-16 units so the ranges line up with the
    /// `NSAttributedString` the cell renders. Keywords tag `.keyword`, all-digit runs tag `.number`.
    static func tokenize(_ text: String) -> [TokenSpan] {
        let ns = text as NSString
        let length = ns.length
        var spans: [TokenSpan] = []
        var index = 0
        while index < length {
            guard isWordUnit(ns.character(at: index)) else {
                index += 1
                continue
            }
            let start = index
            while index < length, isWordUnit(ns.character(at: index)) { index += 1 }
            let range = NSRange(location: start, length: index - start)
            let word = ns.substring(with: range)
            if keywords.contains(word) {
                spans.append(TokenSpan(range: range, role: .keyword))
            } else if word.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal }) {
                spans.append(TokenSpan(range: range, role: .number))
            }
        }
        return spans
    }

    private static func isWordUnit(_ unit: unichar) -> Bool {
        (unit >= 48 && unit <= 57)  // 0-9
            || (unit >= 65 && unit <= 90)  // A-Z
            || (unit >= 97 && unit <= 122)  // a-z
            || unit == 95  // _
    }
}
