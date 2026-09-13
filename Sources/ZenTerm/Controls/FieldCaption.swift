import AppKit

// Rebuilds its own string on a theme swap because `LabeledField` can't recolor its two color runs.
final class FieldCaption: NSTextField, ThemeReapplying {
    private let text: String
    private let isRequired: Bool

    init(_ text: String, required: Bool) {
        self.text = text
        self.isRequired = required
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        let string = NSMutableAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .kern: 0.6,
            ])
        if isRequired {
            string.append(
                NSAttributedString(
                    string: " ✳",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                        .foregroundColor: Theme.current.chrome.accent.nsColor,
                    ]))
        }
        attributedStringValue = string
    }
}
