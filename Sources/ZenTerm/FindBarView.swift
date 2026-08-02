import AppKit

/// The find bar that sits along the bottom of a pane while a scrollback search is up: a query
/// field on the left, the match count on the right.
///
/// Borderless rather than a `FieldBox`, because the bar *is* the field's chrome. A boxed control
/// inside a pane reads as a form widget dropped onto a terminal.
///
/// The bar owns no search state. It reports what the user typed and what they pressed;
/// `SearchController` decides what any of it means.
final class FindBarView: NSView {
    private let glyph = NSImageView()
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")

    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// What the field holds, which is always exactly what gets searched. Setting it does not fire
    /// `onChange`: a seed comes from a selection, and echoing it back as a user edit would re-run
    /// the search it came from.
    var needle: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius

        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
        glyph.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        // One line, always. A needle seeded from a selection can carry a newline, and a field that
        // wraps grows the bar, which displaces the terminal and reflows the grid underneath it. A
        // long needle scrolls inside the field instead.
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Monospaced digits so the count does not jitter sideways as it climbs through a width
        // change: `9 / 17` to `10 / 17` moves the whole row otherwise.
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [glyph, field, count])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
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

    /// How the bar reads while typing (a total, or nothing yet) and after a commit (which match of
    /// how many). `selected` is zero-based, as the backend reports it, and reads one-based.
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
            count.stringValue = "\(selected + 1) / \(total)"
        }
    }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    /// The count as rendered. Its wording carries meaning a state check cannot: "No matches" and
    /// an index that reads one-based off a zero-based report are both only visible here.
    var countTextForTesting: String { count.stringValue }

    var isFieldFirstResponder: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = chrome.accent.nsColor.withAlphaComponent(Self.fillAlpha).cgColor
        glyph.contentTintColor = chrome.ink(alpha: 0.4)
        field.textColor = chrome.foreground.nsColor
        count.textColor = chrome.ink(alpha: 0.5)
        applyPlaceholder()
    }

    /// AppKit's `placeholderString` draws in `placeholderTextColor`, which follows
    /// `effectiveAppearance` rather than `Theme.current`. Same fix, and same reason, as
    /// `PaletteOverlay.applyPlaceholder`.
    private func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in scrollback",
            attributes: [
                .foregroundColor: Theme.current.chrome.ink(alpha: 0.4),
                .font: field.font ?? .systemFont(ofSize: 13),
            ]
        )
    }

    static let height: CGFloat = 26
    private static let cornerRadius: CGFloat = 6
    /// The faintest accent fill the chrome uses, shared with `KeybindChip`'s resting state. Accent
    /// rather than ink so the bar reads as chrome tinted over the pane rather than as a grey panel
    /// laid on it.
    private static let fillAlpha: CGFloat = 0.14
}

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // An IME composing owns its own Esc: cancelling the marked text has to win, or one
            // keystroke discards the composition AND closes the bar. Same guard as `ModalEscape`.
            guard !textView.hasMarkedText() else { return false }
            onCancel?()
            return true
        default:
            return false
        }
    }
}
