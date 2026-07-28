import Foundation

/// Transforms a `FileDiff` into the side-by-side row grid. Removed lines go left, added lines go
/// right, context sits on both, and unpaired changes are padded with a filler on the opposite side so
/// the two columns stay row-aligned. The parallel inline transform is `UnifiedDiff`; both feed the
/// same `DiffPaneTable` (see `DiffRow`).
enum SideBySideDiff {
    static func rows(for file: FileDiff, spans: DiffFileSpans? = nil) -> [DiffRow] {
        var rows: [DiffRow] = []
        for hunk in file.hunks {
            rows.append(.hunkHeader(hunk.header))
            var pendingRemoved: [DiffCell] = []
            var pendingAdded: [DiffCell] = []

            func flushChangeBlock() {
                let count = max(pendingRemoved.count, pendingAdded.count)
                for index in 0..<count {
                    let left = index < pendingRemoved.count ? pendingRemoved[index] : nil
                    let right = index < pendingAdded.count ? pendingAdded[index] : nil
                    rows.append(.split(left: left, right: right))
                }
                pendingRemoved = []
                pendingAdded = []
            }

            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if let old = line.oldLineNumber {
                        pendingRemoved.append(
                            DiffCell(lineNumber: old, text: line.text, kind: .removed, spans: spans?.old(old)))
                    }
                case .added:
                    if let new = line.newLineNumber {
                        pendingAdded.append(
                            DiffCell(lineNumber: new, text: line.text, kind: .added, spans: spans?.new(new)))
                    }
                case .context:
                    flushChangeBlock()
                    guard let old = line.oldLineNumber, let new = line.newLineNumber else { continue }
                    rows.append(
                        .split(
                            left: DiffCell(lineNumber: old, text: line.text, kind: .context, spans: spans?.old(old)),
                            right: DiffCell(lineNumber: new, text: line.text, kind: .context, spans: spans?.new(new))))
                }
            }
            flushChangeBlock()
        }
        return rows
    }
}
