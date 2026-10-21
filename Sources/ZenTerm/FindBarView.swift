import AppKit

final class FindBarView: NSView {
    private let glyph = NSImageView()
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")

    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Setting it doesn't fire `onChange`, so a seed from a selection doesn't re-run its search.
    var needle: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control

        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
        glyph.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        field.font = ChromeType.font(.body)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        count.font = ChromeType.font(.small, face: .digits)
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [glyph, field, count])
        row.orientation = .horizontal
        row.spacing = ChromeMetrics.Spacing.s8
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: ChromeMetrics.Spacing.controlInset, bottom: 0, right: ChromeMetrics.Spacing.controlInset)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `selected` is zero-based and newest-first, libghostty's order; the count shows oldest-first.
    func showCount(total: Int?, selected: Int?) {
        switch (total, selected) {
        case (nil, _):
            count.stringValue = ""
        case (0, nil):
            count.stringValue = "No matches"
        case (1, nil):
            count.stringValue = "1 match"
        case (let total?, nil):
            count.stringValue = "\(total) matches"
        case (let total?, let selected?):
            count.stringValue = "\(max(1, total - selected)) / \(total)"
        }
    }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    var countTextForTesting: String { count.stringValue }

    var isFieldFirstResponder: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    var paneFill: NSColor = .clear {
        didSet { applyFill() }
    }

    private func applyFill() {
        let chrome = Theme.current.chrome
        let tint = chrome.tint(chrome.accent, alpha: ChromeTheme.badgeTint)
        layer?.backgroundColor = ChromeTheme.surface(tint: tint, over: paneFill).cgColor
    }

    var paintedFillForTesting: CGColor? { layer?.backgroundColor }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        applyFill()
        field.applyThemedEditor()
        glyph.contentTintColor = chrome.ink(.muted)
        field.textColor = chrome.ink(.normal)
        count.textColor = chrome.ink(.muted)
        applyPlaceholder()
    }

    private func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in scrollback",
            attributes: [
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .font: field.font ?? ChromeType.font(.body),
            ]
        )
    }

    static let height: CGFloat = ChromeMetrics.Height.control

    static var tintAlphaForTesting: CGFloat {
        Theme.current.chrome.tint(Theme.current.chrome.accent, alpha: ChromeTheme.badgeTint).alphaComponent
    }
}

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    /// An IME composition owns Esc, so marked text never closes the bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !textView.hasMarkedText() else { return false }
            onCancel?()
            return true
        default:
            return false
        }
    }
}
