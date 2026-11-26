import AppKit
import TerminalKit

// The scrollback search field a pane wears over its header's top-right corner while a search runs.
final class FindField: NSView, ThemeReapplying {
    private let glyph = NSImageView()
    private let field = FocusReportingField()
    private let count = NSTextField(labelWithString: "")
    private let divider = Divider(.vertical)
    private lazy var olderButton = stepButton(
        symbol: "chevron.up", label: "Older Match", shortcut: "↩", step: .next)
    private lazy var newerButton = stepButton(
        symbol: "chevron.down", label: "Newer Match", shortcut: "⇧↩", step: .previous)
    private lazy var closeButton = IconButton(
        symbol: "xmark", size: Self.buttonSize, accessibilityLabel: "Close Find", shortcut: { "esc" },
        onClick: { [weak self] in self?.onCancel?() })

    var onChange: ((String) -> Void)?
    var onStep: ((TerminalSearchStep) -> Void)?
    var onCancel: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var isDismissed = false

    /// Setting it doesn't fire `onChange`, so a seed from a selection doesn't re-run its search.
    var needle: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    static let height: CGFloat = ChromeMetrics.Height.control
    // The board's width: no token holds a field this wide, and the pane can always shrink it.
    static let width: CGFloat = 300
    private static let buttonSize = NSSize(width: ChromeMetrics.Height.xs, height: ChromeMetrics.Height.xs)

    // The copy is English throughout, so the grouping follows it rather than the system region.
    private static let countFormat = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))

    init() {
        super.init(frame: .zero)

        glyph.image = IconCatalog.image("magnifyingglass", pointSize: ChromeMetrics.Icon.sm, weight: .regular)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        field.font = ChromeType.font(.small)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.makeSingleLine()
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.onFocus = { [weak self] in self?.onFocusChange?(true) }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        count.font = ChromeType.font(.small, face: .digits)
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let buttons = NSStackView(views: [divider, olderButton, newerButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = ChromeMetrics.Spacing.s2
        buttons.setCustomSpacing(ChromeMetrics.Spacing.s4, after: divider)
        buttons.setHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [glyph, field, count, buttons])
        row.orientation = .horizontal
        row.spacing = ChromeMetrics.Spacing.s8
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: ChromeMetrics.Spacing.controlInset, bottom: 0, right: ChromeMetrics.Spacing.s4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let preferredWidth = widthAnchor.constraint(equalToConstant: Self.width)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.width),
            preferredWidth,
            divider.heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.xs),
        ])

        CardChrome.apply(to: self, tier: .overlay)
        showCount(total: nil, selected: nil)
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func stepButton(symbol: String, label: String, shortcut: String, step: TerminalSearchStep)
        -> IconButton
    {
        IconButton(
            symbol: symbol, size: Self.buttonSize, accessibilityLabel: label, shortcut: { shortcut },
            onClick: { [weak self] in self?.onStep?(step) })
    }

    /// `selected` is zero-based and newest-first, libghostty's order; the count shows oldest-first.
    func showCount(total: Int?, selected: Int?) {
        let format = Self.countFormat
        switch (total, selected) {
        case (nil, _):
            count.stringValue = ""
        case (0, _):
            count.stringValue = "No matches"
        case (1, nil):
            count.stringValue = "1 match"
        case (let total?, nil):
            count.stringValue = "\(total.formatted(format)) matches"
        case (let total?, let selected?):
            count.stringValue = "\(max(1, total - selected).formatted(format)) / \(total.formatted(format))"
        }
        let canStep = (total ?? 0) > 0
        olderButton.isEnabled = canStep
        newerButton.isEnabled = canStep
    }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isDismissed ? nil : super.hitTest(point) }

    var isFieldFirstResponder: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    var countTextForTesting: String { count.stringValue }
    var olderButtonForTesting: IconButton { olderButton }
    var newerButtonForTesting: IconButton { newerButton }
    var closeButtonForTesting: IconButton { closeButton }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: self, tier: .overlay)
        field.applyThemedEditor()
        glyph.contentTintColor = chrome.ink(.muted)
        field.textColor = chrome.ink(.normal)
        count.textColor = chrome.ink(.muted)
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in scrollback",
            attributes: [.foregroundColor: chrome.ink(.faint), .font: field.font ?? ChromeType.font(.small)])
    }
}

extension FindField: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        onFocusChange?(false)
    }

    /// An IME composition owns Return and Esc, so marked text never steps or closes the field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            guard !textView.hasMarkedText() else { return false }
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onStep?(backwards ? .previous : .next)
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

// `controlTextDidBeginEditing` waits for the first keystroke, so a click into the field reports here instead.
private final class FocusReportingField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }
}
