import AppKit

// Rebuilds its own string on a theme swap because a color baked into an attributed run never recolors.
final class SectionCaption: NSTextField, ThemeReapplying {
    private let text: String
    private let isRequired: Bool

    init(_ text: String, required: Bool = false) {
        self.text = text
        self.isRequired = required
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        let ink = Theme.current.chrome.ink(.muted)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.font: ChromeType.sectionLabel, .foregroundColor: ink, .paragraphStyle: paragraph])
        if isRequired {
            string.append(
                NSAttributedString(
                    string: " ✳",
                    attributes: [
                        .font: ChromeType.font(.caption, weight: .medium), .foregroundColor: ink,
                        .paragraphStyle: paragraph,
                    ]))
        }
        attributedStringValue = string
    }
}
