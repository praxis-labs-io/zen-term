import AppKit

/// One diff row: either a full-width hunk header or a `old │ new` line pair with line-number
/// gutters. Laid out manually (no Auto Layout) so a table full of these stays cheap, and reused
/// across scroll positions. Colors read `Theme.current` at configure time, so a live theme swap
/// (a `reloadData`) recolors.
final class DiffLineCell: NSView {
    static let rowHeight: CGFloat = 17
    private static let gutterWidth: CGFloat = 44
    private static let gutterGap: CGFloat = 6

    private let leftGutter = DiffLineCell.label(align: .right)
    private let leftText = DiffLineCell.label(align: .left)
    private let rule = NSView()
    private let rightGutter = DiffLineCell.label(align: .right)
    private let rightText = DiffLineCell.label(align: .left)
    private let headerLabel = DiffLineCell.label(align: .left)
    private var isHeader = false

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        wantsLayer = true
        rule.wantsLayer = true
        for view in [leftGutter, leftText, rule, rightGutter, rightText, headerLabel] { addSubview(view) }
    }

    convenience init() { self.init(id: NSUserInterfaceItemIdentifier("cell")) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func label(align: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.alignment = align
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = true
        label.drawsBackground = false
        return label
    }

    func configure(_ row: SideBySideRow) {
        let chrome = Theme.current.chrome
        switch row {
        case .hunkHeader(let text):
            isHeader = true
            headerLabel.isHidden = false
            headerLabel.stringValue = text
            headerLabel.textColor = chrome.accent.nsColor
            layer?.backgroundColor = chrome.ink(alpha: 0.04).cgColor
            for view in [leftGutter, leftText, rule, rightGutter, rightText] { view.isHidden = true }
        case .lines(let left, let right):
            isHeader = false
            headerLabel.isHidden = true
            rule.isHidden = false
            rule.layer?.backgroundColor = chrome.ink(alpha: 0.08).cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            configureSide(gutter: leftGutter, text: leftText, cell: left, chrome: chrome)
            configureSide(gutter: rightGutter, text: rightText, cell: right, chrome: chrome)
        }
        needsLayout = true
    }

    private func configureSide(gutter: NSTextField, text: NSTextField, cell: DiffCell?, chrome: ChromeTheme) {
        gutter.isHidden = false
        text.isHidden = false
        gutter.textColor = chrome.muted.nsColor
        guard let cell else {
            gutter.stringValue = ""
            text.stringValue = ""
            text.drawsBackground = true
            text.backgroundColor = chrome.ink(alpha: 0.03)  // a filler: the absent side of this row
            return
        }
        gutter.stringValue = "\(cell.lineNumber)"
        text.stringValue = cell.text
        switch cell.kind {
        case .added:
            text.textColor = chrome.positive.nsColor
            text.drawsBackground = true
            text.backgroundColor = chrome.positive.nsColor.withAlphaComponent(0.14)
        case .removed:
            text.textColor = chrome.destructive.nsColor
            text.drawsBackground = true
            text.backgroundColor = chrome.destructive.nsColor.withAlphaComponent(0.14)
        case .context:
            text.textColor = chrome.foreground.nsColor
            text.drawsBackground = false
            text.backgroundColor = .clear
        }
    }

    /// Single-line monospace text height, measured once — `NSTextField` top-aligns text in a taller
    /// frame, so labels are sized to this and centered rather than filling the row.
    private static let textHeight = ("0" as NSString)
        .size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        .height.rounded(.up)

    override func layout() {
        super.layout()
        let gutter = Self.gutterWidth
        let height = bounds.height
        let textY = ((height - Self.textHeight) / 2).rounded()
        let textH = Self.textHeight
        if isHeader {
            headerLabel.frame = NSRect(x: 8, y: textY, width: max(0, bounds.width - 8), height: textH)
            return
        }
        let available = max(0, bounds.width - 2 * gutter - 1)
        let half = (available / 2).rounded(.down)
        leftGutter.frame = NSRect(x: 0, y: textY, width: gutter - Self.gutterGap, height: textH)
        leftText.frame = NSRect(x: gutter, y: textY, width: half, height: textH)
        rule.frame = NSRect(x: gutter + half, y: 0, width: 1, height: height)
        rightGutter.frame = NSRect(x: gutter + half + 1, y: textY, width: gutter - Self.gutterGap, height: textH)
        rightText.frame = NSRect(x: 2 * gutter + half + 1, y: textY, width: available - half, height: textH)
    }
}
