import Foundation

/// Transforms a `FileDiff` into the inline (unified) row list: one row per line in original order
/// (no pairing), each carrying its old and new line numbers — whichever it has — and its kind for the
/// `+`/`−`/` ` sign and tint. Parallel to `SideBySideDiff`; both feed the same `DiffPaneTable` behind
/// the layout-agnostic `DiffRow` model.
enum UnifiedDiff {
    static func rows(for file: FileDiff, spans: DiffFileSpans? = nil) -> [DiffRow] {
        var rows: [DiffRow] = []
        for hunk in file.hunks {
            rows.append(.hunkHeader(hunk.header))
            for line in hunk.lines {
                // A removed line is old-side text; added and context render the new-side text.
                let lineSpans: [TokenSpan]?
                switch line.kind {
                case .removed: lineSpans = spans?.old(line.oldLineNumber)
                case .added, .context: lineSpans = spans?.new(line.newLineNumber)
                }
                rows.append(
                    .unified(
                        text: line.text, kind: line.kind, old: line.oldLineNumber, new: line.newLineNumber,
                        spans: lineSpans))
            }
        }
        return rows
    }
}
