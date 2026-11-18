import AppKit

final class EmptyStateLabel: NSTextField, ThemeReapplying {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = ChromeType.font(.small)
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() { textColor = Theme.current.chrome.ink(.muted) }
}
