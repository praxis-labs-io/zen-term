import Foundation
import SwiftTreeSitter

/// Turns a whole-file source string into per-line syntax spans (ZEN-239). tree-sitter parses whole
/// documents, so we parse the full blob (a bare hunk parses to garbage at its edges) and then map each
/// colored capture onto the file lines it covers. Ranges come out as UTF-16 `NSRange`s aligned to the
/// text, because `SwiftTreeSitter.Parser` parses UTF-16LE and `Node.range` is already UTF-16.
///
/// The parsing and the range→line mapping are separate statics so the mapping is unit-testable on a
/// fixture without a grammar. The off-main orchestration (blob fetch, size ceiling, generation token)
/// lives in the caller.
enum DiffHighlighter {
    /// Parse `text` with `language`, run the highlight `query`, and return colored spans keyed by
    /// 1-based file line number. Returns empty on a parse failure.
    static func perLineSpans(text: String, language: Language, query: Query) -> [Int: [TokenSpan]] {
        let parser = Parser()
        do { try parser.setLanguage(language) } catch { return [:] }
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [:] }
        var captures: [(range: NSRange, role: SyntaxRole)] = []
        for match in query.execute(node: root, in: tree) {
            for capture in match.captures {
                guard let role = SyntaxLanguage.role(forCapture: capture.nameComponents) else { continue }
                let range = capture.node.range
                guard range.length > 0 else { continue }
                captures.append((range, role))
            }
        }
        return perLineSpans(text: text, captures: captures)
    }

    /// Distribute whole-text capture ranges onto the lines they cover, as line-relative spans keyed by
    /// 1-based line number. A capture that crosses a newline (a multiline string or comment) contributes
    /// a clamped span to each line it touches. Pure over its inputs — no grammar needed — so the mapping
    /// is testable directly.
    static func perLineSpans(text: String, captures: [(range: NSRange, role: SyntaxRole)]) -> [Int: [TokenSpan]] {
        let ns = text as NSString
        var lineRanges: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            lineRanges.append(substringRange)
        }
        guard !lineRanges.isEmpty else { return [:] }

        var result: [Int: [TokenSpan]] = [:]
        for (range, role) in captures {
            // Binary-search the first line whose content could still intersect the capture (its end is
            // past the capture's start), then walk forward while lines begin before the capture ends.
            var low = 0
            var high = lineRanges.count
            while low < high {
                let mid = (low + high) / 2
                if lineRanges[mid].location + lineRanges[mid].length <= range.location {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            let rangeEnd = range.location + range.length
            var index = low
            while index < lineRanges.count, lineRanges[index].location < rangeEnd {
                let intersection = NSIntersectionRange(range, lineRanges[index])
                if intersection.length > 0 {
                    let relative = NSRange(
                        location: intersection.location - lineRanges[index].location, length: intersection.length)
                    result[index + 1, default: []].append(TokenSpan(range: relative, role: role))
                }
                index += 1
            }
        }
        return result
    }
}
