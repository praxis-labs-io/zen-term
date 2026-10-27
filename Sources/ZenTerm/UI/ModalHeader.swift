import AppKit

final class ModalHeader: NSStackView, ThemeReapplying {
    private let titleLabel = NSTextField(labelWithString: "")

    init(title: String, accessory: NSView? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = ChromeMetrics.Spacing.s8
        titleLabel.font = ChromeType.font(.title)
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        titleLabel.stringValue = title
        addArrangedSubview(titleLabel)
        guard let accessory else {
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(spacer)
        addArrangedSubview(accessory)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
    }
}
