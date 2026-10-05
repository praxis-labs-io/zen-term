import AppKit

final class FormErrorLabel: NSTextField, ThemeReapplying {
    init(maximumLines: Int = 0) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        font = .systemFont(ofSize: 11, weight: .medium)
        maximumNumberOfLines = maximumLines
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ message: String) {
        stringValue = message
        isHidden = false
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high])
    }

    func clear() { isHidden = true }

    func reapplyTheme() { textColor = Theme.current.chrome.destructive.nsColor }
}
