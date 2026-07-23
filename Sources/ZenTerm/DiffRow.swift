import Foundation

/// A syntax-highlighted run within a line: the character range it covers and the role that resolves
/// its color at render time (ZEN-238). Ranges are `NSRange` because the render path is
/// `NSAttributedString`; `NSRange` is `Equatable`, so the row model stays `Equatable`.
struct TokenSpan: Equatable {
    let range: NSRange
    let role: SyntaxRole
}

/// One cell of a side-by-side row: the line as it sits on its own side (old on the left, new on the
/// right), carrying that side's line number for the gutter and copy-ref.
///
/// `spans` is the syntax highlighting for this line: `nil` means not highlighted (flat fallback);
/// non-`nil` drives per-range attributed coloring. The producer is the `SyntaxSpanSource` seam.
struct DiffCell: Equatable {
    let lineNumber: Int
    let text: String
    let kind: DiffLineKind
    let spans: [TokenSpan]?
}

/// One visual row of the diff pane, in either layout. `DiffPaneTable` is layout-agnostic — it renders
/// whatever rows it's handed and reuses the same navigation for both — so `SideBySideDiff` and
/// `UnifiedDiff` are just two transforms over the same parsed `FileDiff` that feed one table.
///
/// - `hunkHeader`: a full-width `@@ … @@` divider (both layouts).
/// - `split`: side-by-side — an `old | new` pair; a `nil` side is a blank filler that keeps the two
///   columns row-aligned.
/// - `unified`: inline — one line drawn full width, with both gutters (its old and new line numbers,
///   whichever it has) and a `+`/`−`/` ` sign taken from its kind. `spans` is its syntax
///   highlighting (`nil` = not highlighted), mirroring `DiffCell.spans` for inline-layout parity.
enum DiffRow: Equatable {
    case hunkHeader(String)
    case split(left: DiffCell?, right: DiffCell?)
    case unified(text: String, kind: DiffLineKind, old: Int?, new: Int?, spans: [TokenSpan]?)
}
