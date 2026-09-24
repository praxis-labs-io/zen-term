import AppKit

final class ChromeTooltip: HoverCardView {
    enum Style {
        case line
        case paragraph
    }

    // Exposed so copy can be measured against the real wrap budget.
    static let paragraphMaxWidth: CGFloat = 236

    private let labelField: NSTextField

    init(label: String, shortcut: String?, style: Style = .line) {
        labelField = style == .paragraph ? Self.makeParagraphLabel(label) : Self.makeLabel(label)
        super.init(frame: .zero)
        var views: [NSView] = [labelField]
        if let shortcut, !shortcut.isEmpty {
            views.append(KeycapView(shortcut: shortcut, showsBackground: true))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var labelForTesting: String { labelField.stringValue }

    private static func makeParagraphLabel(_ text: String) -> NSTextField {
        let label = makeLabel(text)
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = false
        label.preferredMaxLayoutWidth = paragraphMaxWidth
        label.widthAnchor.constraint(lessThanOrEqualToConstant: paragraphMaxWidth).isActive = true
        return label
    }
}
