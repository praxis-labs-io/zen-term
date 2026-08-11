import Foundation

/// Renders a `DiffSelection` as the `@path:line` reference that gets yanked to the clipboard or sent
/// to an agent. Always names *new-side* line numbers: the reference is only useful if
/// whoever receives it can open the file and find those lines.
///
/// The `@` prefix is the file-mention token Claude Code (and the other agents this feeds) resolves to
/// the file, so a pasted reference reads as a real attachment rather than plain text.
enum DiffReference {
    /// `@path:42-44` for a range, `@path:42` for one line, bare `@path` when there are no new-side
    /// lines to name (a deleted or binary file, or an empty selection). A selection of deletions only
    /// takes the line it follows, so the reference still lands in the right place in the file on disk.
    static func string(path: String, changeKind: ChangeKind, selection: DiffSelection) -> String {
        guard !selection.isEmpty, changeKind != .deleted else { return "@\(path)" }
        guard let range = selection.newRange else {
            // Deletions only: name the line they follow. A file that opens with one has nothing above
            // it, so anchor at the top.
            return "@\(path):\(selection.anchorNewLine ?? 1)"
        }
        return range.lowerBound == range.upperBound
            ? "@\(path):\(range.lowerBound)" : "@\(path):\(range.lowerBound)-\(range.upperBound)"
    }
}
