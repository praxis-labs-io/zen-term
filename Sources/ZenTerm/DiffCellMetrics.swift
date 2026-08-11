import AppKit

/// Shared metrics and subview factories for the diff pane's row cells — `DiffLineCell` (side-by-side)
/// and `UnifiedLineCell` (inline) — so both agree on font, row height, gutter size, and the
/// panning-text / clip setup long lines need.
enum DiffCellMetrics {
    static let rowHeight: CGFloat = 20
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// The slice of a cell its diff line occupies. Normally the whole thing, but a row can be grown to
    /// reserve room for the inline comment box — and then the line stays in the top
    /// `rowHeight` points instead of centring itself in the gap.
    static func lineHeight(in bounds: CGRect) -> CGFloat { min(bounds.height, rowHeight) }

    /// The y-origin, in the cell's own (non-flipped — y=0 is the BOTTOM) coordinate space, of that top
    /// slice. 0 for a plain row (the slice fills the whole cell); positive for a row grown to hold the
    /// comment box, where the reserved room sits *below* the line rather than at the origin.
    static func lineSliceY(in bounds: CGRect) -> CGFloat { bounds.height - lineHeight(in: bounds) }

    /// The y-origin for an element of `height` centered within that top slice — what the gutters, the
    /// hunk header, and the inline sign column position against. A full-slice element (a text clip, the
    /// center rule) is positioned with `lineSliceY` and `lineHeight` directly instead.
    static func lineCenteredY(in bounds: CGRect, height: CGFloat) -> CGFloat {
        (lineSliceY(in: bounds) + (lineHeight(in: bounds) - height) / 2).rounded()
    }

    /// Line-number gutters are left-aligned behind this inset, which the hunk header shares — so the
    /// numbers line up with the `@@ … @@` header text rather than floating right of it.
    static let gutterInset: CGFloat = 8
    /// Gap after a number column, before the content (or the next number column in inline).
    static let gutterTrailing: CGFloat = 8
    /// One monospace digit's advance — the gutter is sized to the file's widest line number times this.
    static let digitWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width
    /// `NSTextField` insets its text a couple of points inside the frame, so a number column has to be a
    /// touch wider than the raw glyph advances or even a single digit truncates to `…`.
    static let numberPadding: CGFloat = 6

    /// The width of a line-number column that fits `digits` digits without truncating (glyph advances
    /// plus the label's own inset), left-aligned.
    static func numberColumnWidth(forDigits digits: Int) -> CGFloat {
        (CGFloat(max(1, digits)) * digitWidth + numberPadding).rounded(.up)
    }

    /// The full gutter width (inset + a `digits`-wide number + trailing gap) — the offset from the row
    /// edge to the content. The pane sizes gutters to the file's widest line number, so a short file
    /// doesn't reserve room for digits it never shows (a 3-digit file's gutter is far tighter than a
    /// 5-digit one's), and long lines get that reclaimed width.
    static func gutterWidth(forDigits digits: Int) -> CGFloat {
        gutterInset + numberColumnWidth(forDigits: digits) + gutterTrailing
    }
    /// A stable gutter width (5 digits) for the width thresholds that must not shift per file — the
    /// auto-fold point would jitter if it moved every time you opened a differently-sized file.
    static let nominalGutterWidth: CGFloat = gutterWidth(forDigits: 5)

    /// Single-line monospace text height, measured once — `NSTextField` top-aligns text in a taller
    /// frame, so labels are sized to this and centered rather than filling the row.
    static let textHeight = ("0" as NSString).size(withAttributes: [.font: font]).height.rounded(.up)

    /// A single-line label for a gutter, sign, or hunk header — never pans, so it truncates. Line-number
    /// gutters left-align (so they sit at `gutterInset`, under the header); the sign passes `.center`.
    static func gutterLabel(align: NSTextAlignment = .left) -> NSTextField {
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
