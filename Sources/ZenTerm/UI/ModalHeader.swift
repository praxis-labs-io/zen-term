import AppKit

final class ModalHeader: NSStackView, ThemeReapplying {
    private let titleLabel = NSTextField(labelWithString: "")
    private(set) var chip: IconBadge?

    init(title: String, chip process: ProcessIcon? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .centerY
        spacing = ChromeMetrics.Spacing.s8
        if let process {
            let chip = IconBadge(process: process, size: .small)
            self.chip = chip
            addArrangedSubview(chip)
        }
        titleLabel.font = ChromeType.font(.title)
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        titleLabel.stringValue = title
        addArrangedSubview(titleLabel)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        chip?.reapplyTheme()
    }
}
