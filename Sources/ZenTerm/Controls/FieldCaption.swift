import AppKit

/// A small-caps field caption ("WORKSPACE NAME ✳"); a required field marks it with a trailing
/// accent asterisk. Its attributed string bakes in two color runs (the label ink, the required
/// asterisk's accent) that `LabeledField` — a shared primitive with no insight into that structure
/// — can't recolor itself, so this rebuilds its own string fresh in `reapplyTheme()` and conforms
/// to `ThemeReapplying` so `LabeledField` can reach it generically. Shared by the modal forms
/// (`AddWorkspaceOverlay`, `ToolFloatFormOverlay`).
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
                .foregroundColor: Theme.current.chrome.ink(alpha: 0.4),
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
