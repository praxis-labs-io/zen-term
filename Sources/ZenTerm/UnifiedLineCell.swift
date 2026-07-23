import AppKit

/// An inline (unified) diff row: one line drawn full width, with old and new line-number gutters, a
/// `+`/`−`/` ` sign, and the text in a clipping container that pans by the shared `horizontalOffset`
/// (ZEN-241) — the same panning as `DiffLineCell`, one column instead of two. The sign and gutters stay
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
        guard case .unified(let lineText, let kind, let old, let new) = row else { return }
        let chrome = Theme.current.chrome
        layer?.backgroundColor = NSColor.clear.cgColor
        oldGutter.textColor = chrome.muted.nsColor
        newGutter.textColor = chrome.muted.nsColor
        oldGutter.stringValue = old.map(String.init) ?? ""
        newGutter.stringValue = new.map(String.init) ?? ""
        text.stringValue = lineText
        switch kind {
        case .added:
            sign.stringValue = "+"
            sign.textColor = chrome.positive.nsColor
            text.textColor = chrome.positive.nsColor
            clip.layer?.backgroundColor = chrome.positive.nsColor.withAlphaComponent(0.14).cgColor
        case .removed:
            sign.stringValue = "−"
            sign.textColor = chrome.destructive.nsColor
            text.textColor = chrome.destructive.nsColor
            clip.layer?.backgroundColor = chrome.destructive.nsColor.withAlphaComponent(0.14).cgColor
        case .context:
            sign.stringValue = ""
            text.textColor = chrome.foreground.nsColor
            clip.layer?.backgroundColor = NSColor.clear.cgColor
        }
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
        let textHeight = DiffCellMetrics.textHeight
        let textY = ((bounds.height - textHeight) / 2).rounded()
        // Old and new numbers left-align adjacent — the old under the hunk header at `inset`, the new one
        // trailing-gap past it — then the sign, then the panning text.
        oldGutter.frame = NSRect(x: inset, y: textY, width: numbers, height: textHeight)
        newGutter.frame = NSRect(x: inset + numbers + trailing, y: textY, width: numbers, height: textHeight)
        sign.frame = NSRect(x: inset + 2 * numbers + 2 * trailing, y: textY, width: Self.signWidth, height: textHeight)
        let clipX = Self.contentX(gutterWidth: gutterWidth)
        clip.frame = NSRect(x: clipX, y: 0, width: max(0, bounds.width - clipX), height: bounds.height)
        repositionText()
    }

    private func repositionText() {
        let textHeight = DiffCellMetrics.textHeight
        let textY = ((bounds.height - textHeight) / 2).rounded()
        text.frame = NSRect(
            x: -horizontalOffset, y: textY, width: text.intrinsicContentSize.width, height: textHeight)
    }
}
