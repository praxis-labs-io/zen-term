import AppKit

final class FormErrorLabel: NSTextField, ThemeReapplying {
    enum Tone { case destructive, warning, muted }

    private(set) var tone = Tone.destructive
    private var announced: String?
    var onAnnounceForTesting: ((String) -> Void)?

    init(maximumLines: Int = 0) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        font = ChromeType.font(.caption, weight: .medium)
        maximumNumberOfLines = maximumLines
        isHidden = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ message: String, tone: Tone = .destructive) {
        stringValue = message
        self.tone = tone
        isHidden = false
        reapplyTheme()
        guard message != announced else { return }
        announced = message
        guard window != nil else { return }
        onAnnounceForTesting?(message)
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high])
    }

    func clear() {
        isHidden = true
        announced = nil
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        switch tone {
        case .destructive: textColor = chrome.destructive.nsColor
        case .warning: textColor = chrome.warning.nsColor
        case .muted: textColor = chrome.ink(.muted)
        }
    }
}
