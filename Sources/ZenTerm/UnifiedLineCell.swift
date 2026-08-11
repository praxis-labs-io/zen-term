import AppKit

/// An inline (unified) diff row: one line drawn full width, with old and new line-number gutters, a
/// `+`/`−`/` ` sign, and the text in a clipping container that pans by the shared `horizontalOffset`
/// — the same panning as `DiffLineCell`, one column instead of two. The sign and gutters stay
/// frozen while the text slides. Hunk headers are drawn by `DiffLineCell`; this cell only renders
/// `.unified` rows. Manual layout, reused across scroll, reads `Theme.current` at configure time.
final class UnifiedLineCell: NSView, DiffPanningCell {
    private let oldGutter = DiffCellMetrics.gutterLabel()
    private let newGutter = DiffCellMetrics.gutterLabel()
    private let sign = DiffCellMetrics.gutterLabel(align: .center)
    private let clip = DiffCellMetrics.clipView()
    private let text = DiffCellMetrics.contentLabel()

    private static let signWidth: CGFloat = 14

    var horizontalOffset: CGFloat = 0 {
        didSet { if horizontalOffset != oldValue { repositionText() } }
    }

    /// The line-number gutter width for the current file, sized to its widest line number by the pane.
    var gutterWidth: CGFloat = DiffCellMetrics.nominalGutterWidth {
        didSet { if gutterWidth != oldValue { needsLayout = true } }
    }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        wantsLayer = true
        clip.addSubview(text)
        for view in [oldGutter, newGutter, sign, clip] { addSubview(view) }
    }

    convenience init() { self.init(id: NSUserInterfaceItemIdentifier("unified-cell")) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ row: DiffRow) {
        guard case .unified(let lineText, let kind, let old, let new, let spans) = row else { return }
        let chrome = Theme.current.chrome
        layer?.backgroundColor = NSColor.clear.cgColor
        oldGutter.textColor = chrome.muted.nsColor
        newGutter.textColor = chrome.muted.nsColor
        oldGutter.stringValue = old.map(String.init) ?? ""
        newGutter.stringValue = new.map(String.init) ?? ""
        // The sign and kind-based background tint are unchanged; syntax colors ride on top of the tint.
        switch kind {
        case .added:
            sign.stringValue = "+"
            sign.textColor = chrome.positive.nsColor
            clip.layer?.backgroundColor = chrome.positive.nsColor.withAlphaComponent(0.14).cgColor
        case .removed:
            sign.stringValue = "−"
            sign.textColor = chrome.destructive.nsColor
            clip.layer?.backgroundColor = chrome.destructive.nsColor.withAlphaComponent(0.14).cgColor
        case .context:
            sign.stringValue = ""
            clip.layer?.backgroundColor = NSColor.clear.cgColor
        }
        // With spans: syntax foreground over the tint. Without: today's flat fg per kind.
        if let spans {
            text.attributedStringValue = SyntaxAttributedText.make(
                lineText, spans: spans, base: chrome.foreground.nsColor, font: DiffCellMetrics.font, chrome: chrome)
        } else {
            text.stringValue = lineText
            text.textColor = SyntaxAttributedText.flatColor(for: kind, chrome: chrome)
        }
        // Resize the text to the new content *now* — see `DiffLineCell.configure`: a cell reused from a
        // shorter row would otherwise keep that row's narrower frame and clip this line's tail.
        repositionText()
        needsLayout = true
    }

    /// The text column's width for a total row width and gutter width — the inline pane's scroll range
    /// is the widest line minus this. The two number columns sit adjacent (one trailing gap between),
    /// then the sign, so the reserved lead is `inset + 2·digits + 2·gap + sign`, not two full gutters.
    static func columnWidth(forTotalWidth totalWidth: CGFloat, gutterWidth: CGFloat) -> CGFloat {
        max(0, totalWidth - contentX(gutterWidth: gutterWidth))
    }

    /// Where the panning text column begins: past the old and new number columns and the sign.
    private static func contentX(gutterWidth: CGFloat) -> CGFloat {
        let numbers = max(0, gutterWidth - DiffCellMetrics.gutterInset - DiffCellMetrics.gutterTrailing)
        return DiffCellMetrics.gutterInset + 2 * numbers + 2 * DiffCellMetrics.gutterTrailing + signWidth
    }

    override func layout() {
        super.layout()
        let inset = DiffCellMetrics.gutterInset
        let trailing = DiffCellMetrics.gutterTrailing
        let numbers = max(0, gutterWidth - inset - trailing)  // one line-number column's digit width
        let lineHeight = DiffCellMetrics.lineHeight(in: bounds)
        // The cell is non-flipped (y=0 is the bottom), so a row grown for the comment box
        // needs the slice pinned explicitly to the top rather than centred in the whole, taller bounds.
        let sliceY = DiffCellMetrics.lineSliceY(in: bounds)
        // Old and new numbers left-align adjacent — the old under the hunk header at `inset`, the new one
        // trailing-gap past it — then the sign, then the panning text.
        oldGutter.frame = NSRect(x: inset, y: gutterTextY, width: numbers, height: DiffCellMetrics.textHeight)
        newGutter.frame = NSRect(
            x: inset + numbers + trailing, y: gutterTextY, width: numbers, height: DiffCellMetrics.textHeight)
        sign.frame = NSRect(
            x: inset + 2 * numbers + 2 * trailing, y: gutterTextY, width: Self.signWidth,
            height: DiffCellMetrics.textHeight)
        let clipX = Self.contentX(gutterWidth: gutterWidth)
        clip.frame = NSRect(x: clipX, y: sliceY, width: max(0, bounds.width - clipX), height: lineHeight)
        repositionText()
    }

    /// Where the gutters and sign sit in the CELL's own (non-flipped) coordinate space. A row can be
    /// **taller** than one line — the inline comment box reserves the rest of it — so this
    /// centres in the line's own slice at the top, never in the whole row, which would drop it into the
    /// middle of the reserved gap.
    private var gutterTextY: CGFloat {
        DiffCellMetrics.lineCenteredY(in: bounds, height: DiffCellMetrics.textHeight)
    }

    /// Slide the text label to the shared offset. `text` is a subview of `clip`, which `layout()` keeps
    /// exactly `lineHeight` tall and pins to the row's top slice — so, unlike `gutterTextY`, this centres
    /// purely within `clip`'s own bounds, with no slice offset of its own to add.
    private func repositionText() {
        let textY = ((DiffCellMetrics.lineHeight(in: bounds) - DiffCellMetrics.textHeight) / 2).rounded()
        text.frame = NSRect(
            x: -horizontalOffset, y: textY, width: text.intrinsicContentSize.width,
            height: DiffCellMetrics.textHeight)
    }
}
