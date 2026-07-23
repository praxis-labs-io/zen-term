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

    /// The text column's width for a total row width — the inline pane's scroll range is the widest
    /// line minus this.
    static func columnWidth(forTotalWidth totalWidth: CGFloat) -> CGFloat {
        max(0, totalWidth - 2 * DiffCellMetrics.gutterWidth - signWidth)
    }

    override func layout() {
        super.layout()
        let gutter = DiffCellMetrics.gutterWidth
        let gap = DiffCellMetrics.gutterGap
        let textHeight = DiffCellMetrics.textHeight
        let textY = ((bounds.height - textHeight) / 2).rounded()
        oldGutter.frame = NSRect(x: 0, y: textY, width: gutter - gap, height: textHeight)
        newGutter.frame = NSRect(x: gutter, y: textY, width: gutter - gap, height: textHeight)
        sign.frame = NSRect(x: 2 * gutter, y: textY, width: Self.signWidth, height: textHeight)
        let clipX = 2 * gutter + Self.signWidth
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
