import AppKit

/// Shared metrics and subview factories for the diff pane's row cells — `DiffLineCell` (side-by-side)
/// and `UnifiedLineCell` (inline) — so both agree on font, row height, gutter size, and the
/// panning-text / clip setup that ZEN-241 introduced.
enum DiffCellMetrics {
    static let rowHeight: CGFloat = 20
    static let gutterWidth: CGFloat = 44
    static let gutterGap: CGFloat = 6
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Single-line monospace text height, measured once — `NSTextField` top-aligns text in a taller
    /// frame, so labels are sized to this and centered rather than filling the row.
    static let textHeight = ("0" as NSString).size(withAttributes: [.font: font]).height.rounded(.up)

    /// A single-line label for a gutter, sign, or hunk header — never pans, so it truncates.
    static func gutterLabel(align: NSTextAlignment = .right) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.alignment = align
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = true
        label.drawsBackground = false
        return label
    }

    /// The panning line text: drawn full width (`.byClipping`, never truncated) and hidden past its
    /// column edge by a clip container, so scrolling reveals the tail instead of a `…`.
    static func contentLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.isSelectable = true
        label.drawsBackground = false
        return label
    }

    /// A column's clip: masks its panning text to the column, and carries the line's change tint so the
    /// highlight fills the column and stays put while the text slides under it.
    static func clipView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }
}

/// A diff cell whose text column(s) pan by a shared horizontal offset. `DiffPaneTable` sets it on every
/// visible row so both layouts scroll in lockstep, without the table knowing which cell it holds.
protocol DiffPanningCell: NSView {
    var horizontalOffset: CGFloat { get set }
}
