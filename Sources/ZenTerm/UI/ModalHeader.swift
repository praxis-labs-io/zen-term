import AppKit

final class ModalHeader: NSStackView, ThemeReapplying {
    private let titleLabel = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .centerY
        titleLabel.font = ChromeType.font(.title)
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        titleLabel.stringValue = title
        addArrangedSubview(titleLabel)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
    }
}
