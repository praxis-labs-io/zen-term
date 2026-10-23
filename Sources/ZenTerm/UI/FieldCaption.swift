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
            string: text,
            attributes: [
                .font: ChromeType.sectionLabel,
                .foregroundColor: Theme.current.chrome.ink(.muted),
            ])
        if isRequired {
            string.append(
                NSAttributedString(
                    string: " ✳",
                    attributes: [
                        .font: ChromeType.font(.caption, weight: .medium),
                        .foregroundColor: Theme.current.chrome.ink(.muted),
                    ]))
        }
        attributedStringValue = string
    }
}
