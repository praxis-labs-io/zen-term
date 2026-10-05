import AppKit

final class SSHHostRow: SettingsFocusRow {
    let host: String
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let statusLabel = NSTextField(labelWithString: "")
    private var status: SSHHostStatus

    init(host: String, title: String, subtitle: String?, status: SSHHostStatus) {
        self.host = host
        self.status = status
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = NSTextField(labelWithString: subtitle ?? "")

        super.init()

        setAccessibilityRole(.button)
        setAccessibilityLabel("Edit \(title)")

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = subtitle == nil
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [labels, spacer, statusLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        pin(controls)
        showStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setStatus(_ status: SSHHostStatus) {
        guard status != self.status else { return }
        self.status = status
        showStatus()
    }

    override func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
        statusLabel.textColor = status.ink
        super.reapplyTheme()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    var renderedStatusForTesting: (word: String, ink: NSColor?) { (statusLabel.stringValue, statusLabel.textColor) }

    private func showStatus() {
        statusLabel.stringValue = status.word
        statusLabel.textColor = status.ink
        setAccessibilityValue(status.word)
    }
}
