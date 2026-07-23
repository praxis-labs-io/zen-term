import AppKit

/// One diff row: either a full-width hunk header or a `old │ new` line pair with line-number gutters.
/// Long lines don't wrap or truncate — each side's text sits in a clipping container and pans by a
/// shared `horizontalOffset` (ZEN-241), so both columns scroll together while the gutters and center
/// rule stay frozen. Laid out manually (no Auto Layout) so a table full of these stays cheap, and
/// reused across scroll positions. Colors read `Theme.current` at configure time, so a live theme
/// swap (a `reloadData`) recolors.
final class DiffLineCell: NSView {
    static let rowHeight: CGFloat = 20
    private static let gutterWidth: CGFloat = 44
    private static let gutterGap: CGFloat = 6

    private let leftGutter = DiffLineCell.gutterLabel()
    private let rightGutter = DiffLineCell.gutterLabel()
    private let leftClip = DiffLineCell.clipView()
    private let rightClip = DiffLineCell.clipView()
    private let leftText = DiffLineCell.contentLabel()
    private let rightText = DiffLineCell.contentLabel()
    private let rule = NSView()
    private let headerLabel = DiffLineCell.gutterLabel(align: .left)
    private var isHeader = false

    /// Shared horizontal pan for both text columns (the gutters and rule stay frozen). Set by the pane
    /// so every visible row scrolls in lockstep.
    var horizontalOffset: CGFloat = 0 {
        didSet { if horizontalOffset != oldValue { repositionText() } }
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

    convenience init() { self.init(id: NSUserInterfaceItemIdentifier("cell")) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// A single-line label for the gutters and hunk header — these never pan, so they truncate.
    private static func gutterLabel(align: NSTextAlignment = .right) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.alignment = align
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = true
        label.drawsBackground = false
        return label
    }

    /// The panning line text: drawn full-width (`.byClipping`, never truncated) and hidden past the
    /// column edge by its clip container, so scrolling reveals the tail instead of a `…`.
    private static func contentLabel() -> NSTextField {
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
    private static func clipView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
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
            for view in [leftGutter, leftClip, rule, rightGutter, rightClip] { view.isHidden = true }
        case .lines(let left, let right):
            isHeader = false
            headerLabel.isHidden = true
            rule.isHidden = false
            rule.layer?.backgroundColor = chrome.ink(alpha: 0.08).cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            for view in [leftGutter, leftClip, rightGutter, rightClip] { view.isHidden = false }
            configureSide(gutter: leftGutter, clip: leftClip, text: leftText, cell: left, chrome: chrome)
            configureSide(gutter: rightGutter, clip: rightClip, text: rightText, cell: right, chrome: chrome)
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
        text.stringValue = cell.text
        switch cell.kind {
        case .added:
            text.textColor = chrome.positive.nsColor
            clip.layer?.backgroundColor = chrome.positive.nsColor.withAlphaComponent(0.14).cgColor
        case .removed:
            text.textColor = chrome.destructive.nsColor
            clip.layer?.backgroundColor = chrome.destructive.nsColor.withAlphaComponent(0.14).cgColor
        case .context:
            text.textColor = chrome.foreground.nsColor
            clip.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// Single-line monospace text height, measured once — `NSTextField` top-aligns text in a taller
    /// frame, so labels are sized to this and centered rather than filling the row.
    private static let textHeight = ("0" as NSString)
        .size(withAttributes: [.font: font])
        .height.rounded(.up)

    /// One text column's width for a given total row width — the pane's horizontal scroll range is the
    /// widest line minus this.
    static func columnWidth(forTotalWidth totalWidth: CGFloat) -> CGFloat {
        let available = max(0, totalWidth - 2 * gutterWidth - 1)
        return (available / 2).rounded(.down)
    }

    override func layout() {
        super.layout()
        let gutter = Self.gutterWidth
        let height = bounds.height
        let textY = ((height - Self.textHeight) / 2).rounded()
        if isHeader {
            headerLabel.frame = NSRect(x: 8, y: textY, width: max(0, bounds.width - 8), height: Self.textHeight)
            return
        }
        let available = max(0, bounds.width - 2 * gutter - 1)
        let half = (available / 2).rounded(.down)
        leftGutter.frame = NSRect(x: 0, y: textY, width: gutter - Self.gutterGap, height: Self.textHeight)
        leftClip.frame = NSRect(x: gutter, y: 0, width: half, height: height)
        rule.frame = NSRect(x: gutter + half, y: 0, width: 1, height: height)
        rightGutter.frame = NSRect(
            x: gutter + half + 1, y: textY, width: gutter - Self.gutterGap, height: Self.textHeight)
        rightClip.frame = NSRect(x: 2 * gutter + half + 1, y: 0, width: available - half, height: height)
        repositionText()
    }

    /// Slide both text labels to the shared offset within their (fixed) clip columns.
    private func repositionText() {
        let textY = ((bounds.height - Self.textHeight) / 2).rounded()
        leftText.frame = NSRect(
            x: -horizontalOffset, y: textY, width: leftText.intrinsicContentSize.width, height: Self.textHeight)
        rightText.frame = NSRect(
            x: -horizontalOffset, y: textY, width: rightText.intrinsicContentSize.width, height: Self.textHeight)
    }
}
