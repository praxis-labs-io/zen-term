import AppKit

// A centered wrapping label that breaks its text into lines of similar width, never truncating.
final class BalancedLabel: NSTextField {
    var wrapWidth: CGFloat {
        didSet { if wrapWidth != oldValue { invalidateIntrinsicContentSize() } }
    }

    override var stringValue: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var font: NSFont? {
        didSet { invalidateIntrinsicContentSize() }
    }

    init(font: NSFont, wrapWidth: CGFloat) {
        self.wrapWidth = wrapWidth
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        self.font = font
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        guard !stringValue.isEmpty, wrapWidth > 0 else { return .zero }
        let width = balancedWidth()
        return NSSize(width: width, height: height(at: width))
    }

    // The narrowest whole-point width that keeps the line count the text has at `wrapWidth`.
    private func balancedWidth() -> CGFloat {
        let widest = wrapWidth.rounded(.down)
        let lineCountHeight = height(at: widest)
        var fits = widest
        var tooNarrow: CGFloat = 0
        while fits - tooNarrow > 1 {
            let middle = ((fits + tooNarrow) / 2).rounded(.down)
            if height(at: middle) <= lineCountHeight { fits = middle } else { tooNarrow = middle }
        }
        return fits
    }

    private func height(at width: CGFloat) -> CGFloat {
        guard let cell else { return 0 }
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
            .rounded(.up)
    }

    var lineCountForTesting: Int {
        guard let font, let cell else { return 0 }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let bounds = NSRect(x: 0, y: 0, width: frame.width, height: .greatestFiniteMagnitude)
        return Int((cell.cellSize(forBounds: bounds).height / lineHeight).rounded())
    }
}
