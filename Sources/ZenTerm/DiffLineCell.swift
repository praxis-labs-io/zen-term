import AppKit

/// A side-by-side diff row: a full-width hunk header, or an `old │ new` line pair with line-number
/// gutters. Long lines don't wrap or truncate — each side's text sits in a clipping container and pans
/// by a shared `horizontalOffset` (ZEN-241), so both columns scroll together while the gutters and
/// center rule stay frozen. Inline (`.unified`) rows are drawn by `UnifiedLineCell`, not this cell.
/// Laid out manually (no Auto Layout) so a table full of these stays cheap, and reused across scroll
/// positions. Colors read `Theme.current` at configure time, so a live theme swap (`reloadData`)
/// recolors.
final class DiffLineCell: NSView, DiffPanningCell {
    private let leftGutter = DiffCellMetrics.gutterLabel()
    private let rightGutter = DiffCellMetrics.gutterLabel()
    private let leftClip = DiffCellMetrics.clipView()
    private let rightClip = DiffCellMetrics.clipView()
    private let leftText = DiffCellMetrics.contentLabel()
    private let rightText = DiffCellMetrics.contentLabel()
    private let rule = NSView()
    private let headerLabel = DiffCellMetrics.gutterLabel(align: .left)
    private var isHeader = false

    /// Shared horizontal pan for both text columns (the gutters and rule stay frozen). Set by the pane
    /// so every visible row scrolls in lockstep.
    var horizontalOffset: CGFloat = 0 {
        didSet { if horizontalOffset != oldValue { repositionText() } }
    }

    /// The line-number gutter width for the current file, sized to its widest line number by the pane so
    /// short files don't waste horizontal space. Defaults to the nominal width until the pane sets it.
    var gutterWidth: CGFloat = DiffCellMetrics.nominalGutterWidth {
        didSet { if gutterWidth != oldValue { needsLayout = true } }
    }

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        wantsLayer = true
        rule.wantsLayer = true
        leftClip.addSubview(leftText)
        rightClip.addSubview(rightText)
        for view in [leftGutter, leftClip, rule, rightGutter, rightClip, headerLabel] { addSubview(view) }
    }

    convenience init() { self.init(id: NSUserInterfaceItemIdentifier("split-cell")) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ row: DiffRow) {
        let chrome = Theme.current.chrome
        switch row {
        case .hunkHeader(let text):
            isHeader = true
            headerLabel.isHidden = false
            headerLabel.stringValue = text
            headerLabel.textColor = chrome.accent.nsColor
            layer?.backgroundColor = chrome.ink(alpha: 0.04).cgColor
            for view in [leftGutter, leftClip, rule, rightGutter, rightClip] { view.isHidden = true }
        case .split(let left, let right):
            isHeader = false
            headerLabel.isHidden = true
            rule.isHidden = false
            rule.layer?.backgroundColor = chrome.ink(alpha: 0.08).cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            for view in [leftGutter, leftClip, rightGutter, rightClip] { view.isHidden = false }
            configureSide(gutter: leftGutter, clip: leftClip, text: leftText, cell: left, chrome: chrome)
            configureSide(gutter: rightGutter, clip: rightClip, text: rightText, cell: right, chrome: chrome)
        case .unified:
            // Inline rows are routed to `UnifiedLineCell`; a split cell never receives one.
            isHeader = false
            for view in subviews { view.isHidden = true }
        }
        needsLayout = true
    }

    private func configureSide(
        gutter: NSTextField, clip: NSView, text: NSTextField, cell: DiffCell?, chrome: ChromeTheme
    ) {
        gutter.textColor = chrome.muted.nsColor
        guard let cell else {
            gutter.stringValue = ""
            text.stringValue = ""
            clip.layer?.backgroundColor = chrome.ink(alpha: 0.03).cgColor  // a filler: the absent side
            return
        }
        gutter.stringValue = "\(cell.lineNumber)"
        // The kind-based background tint is unchanged; syntax colors ride on top of it.
        switch cell.kind {
        case .added:
            clip.layer?.backgroundColor = chrome.positive.nsColor.withAlphaComponent(0.14).cgColor
        case .removed:
            clip.layer?.backgroundColor = chrome.destructive.nsColor.withAlphaComponent(0.14).cgColor
        case .context:
            clip.layer?.backgroundColor = NSColor.clear.cgColor
        }
        // With spans: syntax foreground over the tint (GitHub/Zed style). Without: today's flat fg per kind.
        if let spans = cell.spans {
            text.attributedStringValue = SyntaxAttributedText.make(
                cell.text, spans: spans, base: chrome.foreground.nsColor, font: DiffCellMetrics.font, chrome: chrome)
        } else {
            text.stringValue = cell.text
            text.textColor = SyntaxAttributedText.flatColor(for: cell.kind, chrome: chrome)
        }
    }

    /// One text column's width for a given total row width and gutter width — the pane's horizontal
    /// scroll range in side-by-side is the widest line minus this.
    static func columnWidth(forTotalWidth totalWidth: CGFloat, gutterWidth: CGFloat) -> CGFloat {
        let available = max(0, totalWidth - 2 * gutterWidth - 1)
        return (available / 2).rounded(.down)
    }

    override func layout() {
        super.layout()
        let inset = DiffCellMetrics.gutterInset
        let gutter = gutterWidth
        let textHeight = DiffCellMetrics.textHeight
        let height = bounds.height
        let textY = ((height - textHeight) / 2).rounded()
        if isHeader {
            headerLabel.frame = NSRect(x: inset, y: textY, width: max(0, bounds.width - inset), height: textHeight)
            return
        }
        let available = max(0, bounds.width - 2 * gutter - 1)
        let half = (available / 2).rounded(.down)
        // Gutters left-align at `inset` (under the header); their labels span to the column edge so the
        // digits start at the inset and the trailing gap sits between them and the content.
        leftGutter.frame = NSRect(x: inset, y: textY, width: gutter - inset, height: textHeight)
        leftClip.frame = NSRect(x: gutter, y: 0, width: half, height: height)
        rule.frame = NSRect(x: gutter + half, y: 0, width: 1, height: height)
        rightGutter.frame = NSRect(
            x: gutter + half + 1 + inset, y: textY, width: gutter - inset, height: textHeight)
        rightClip.frame = NSRect(x: 2 * gutter + half + 1, y: 0, width: available - half, height: height)
        repositionText()
    }

    /// Slide both text labels to the shared offset within their (fixed) clip columns.
    private func repositionText() {
        let textHeight = DiffCellMetrics.textHeight
        let textY = ((bounds.height - textHeight) / 2).rounded()
        leftText.frame = NSRect(
            x: -horizontalOffset, y: textY, width: leftText.intrinsicContentSize.width, height: textHeight)
        rightText.frame = NSRect(
            x: -horizontalOffset, y: textY, width: rightText.intrinsicContentSize.width, height: textHeight)
    }
}
