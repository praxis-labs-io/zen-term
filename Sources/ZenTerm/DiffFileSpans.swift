import Foundation

/// Syntax spans for one file's two sides, keyed by 1-based file line number (ZEN-239). The old side is
/// keyed by a line's `oldLineNumber`, the new side by its `newLineNumber`; a diff row looks up whichever
/// side it sits on. Position-keyed rather than text-keyed because the highlighter parses each whole-file
/// blob and maps token ranges back onto file line numbers. Produced off-main by `DiffHighlighter` and
/// handed to the row transforms (`SideBySideDiff` / `UnifiedDiff`).
struct DiffFileSpans: Equatable {
    let old: [Int: [TokenSpan]]
    let new: [Int: [TokenSpan]]

    func old(_ line: Int?) -> [TokenSpan]? { line.flatMap { old[$0] } }
    func new(_ line: Int?) -> [TokenSpan]? { line.flatMap { new[$0] } }
}
