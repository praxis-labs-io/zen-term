import Foundation

/// One cell of a side-by-side row: the line as it sits on its own side (old on the left, new
/// on the right), carrying that side's line number for the gutter and copy-ref.
struct DiffCell: Equatable {
    let lineNumber: Int
    let text: String
    let kind: DiffLineKind
}

/// A single visual row of the side-by-side view: either a full-width hunk header, or a pair of
/// cells. A `nil` cell is a blank filler that keeps both columns the same height when one side
/// has more lines than the other.
enum SideBySideRow: Equatable {
    case hunkHeader(String)
    case lines(left: DiffCell?, right: DiffCell?)
}

/// Transforms a `FileDiff` into the row grid the side-by-side renderer draws. Removed lines go
/// left, added lines go right, context sits on both, and unpaired changes are padded with a
/// filler on the opposite side so the two columns stay row-aligned. This is the single
/// `FileDiff`->layout method; the unified renderer (ZEN-228) is a separate transform over the
/// same `FileDiff`.
enum SideBySideDiff {
    static func rows(for file: FileDiff) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        for hunk in file.hunks {
            rows.append(.hunkHeader(hunk.header))
            var pendingRemoved: [DiffCell] = []
            var pendingAdded: [DiffCell] = []

            func flushChangeBlock() {
                let count = max(pendingRemoved.count, pendingAdded.count)
                for index in 0..<count {
                    let left = index < pendingRemoved.count ? pendingRemoved[index] : nil
                    let right = index < pendingAdded.count ? pendingAdded[index] : nil
                    rows.append(.lines(left: left, right: right))
                }
                pendingRemoved = []
                pendingAdded = []
            }

            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if let old = line.oldLineNumber {
                        pendingRemoved.append(DiffCell(lineNumber: old, text: line.text, kind: .removed))
                    }
                case .added:
                    if let new = line.newLineNumber {
                        pendingAdded.append(DiffCell(lineNumber: new, text: line.text, kind: .added))
                    }
                case .context:
                    flushChangeBlock()
                    guard let old = line.oldLineNumber, let new = line.newLineNumber else { continue }
                    rows.append(
                        .lines(
                            left: DiffCell(lineNumber: old, text: line.text, kind: .context),
                            right: DiffCell(lineNumber: new, text: line.text, kind: .context)))
                }
            }
            flushChangeBlock()
        }
        return rows
    }
}
