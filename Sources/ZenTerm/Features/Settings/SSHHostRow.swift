import AppKit

final class SSHHostRow: SettingsFocusRow {
    let host: String
    private let statusLabel = NSTextField(labelWithString: "")
    private var status: SSHHostStatus

    init(host: String, title: String, subtitle: String?, status: SSHHostStatus) {
        self.host = host
        self.status = status
        super.init(Content(title: title, subtitle: subtitle))
        setAccessibilityLabel("Edit \(title)")
        statusLabel.font = ChromeType.font(.small)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessories = [statusLabel]
        showStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setStatus(_ status: SSHHostStatus) {
        guard status != self.status else { return }
        self.status = status
        showStatus()
    }

    override func reapplyTheme() {
        statusLabel.textColor = Theme.current.chrome.ink(.muted)
        super.reapplyTheme()
    }

    #if DEBUG
        var renderedStatusForTesting: (word: String, ink: NSColor?) {
            (statusLabel.stringValue, statusLabel.textColor)
        }

        var statusFrameInRowForTesting: NSRect { statusLabel.convert(statusLabel.bounds, to: self) }
    #endif

    private func showStatus() {
        statusLabel.stringValue = status.word
        statusLabel.textColor = Theme.current.chrome.ink(.muted)
        setAccessibilityValue(status.word)
    }
}
