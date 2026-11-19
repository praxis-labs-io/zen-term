import AppKit

final class KeybindRow: NSView, ThemeReapplying {
    enum MessageKind: Equatable {
        case diagnostic
        case explanation
        case notice
        case failure
    }

    let action: KeyInterceptor.ReservedChord
    let chip = KeybindChip()
    private let titleLabel: NSTextField
    private let messageLabel = FormErrorLabel()
    private(set) var messageKind: MessageKind?
    private var lastShortcut = ""

    init(action: KeyInterceptor.ReservedChord, title: String) {
        self.action = action

        let label = NSTextField(labelWithString: title)
        label.font = ChromeType.font(.body)
        label.textColor = Theme.current.chrome.ink(.normal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel = label

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [label, spacer, chip])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = ChromeMetrics.Spacing.s8

        let stack = NSStackView(views: [controls, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ChromeMetrics.Spacing.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(currentShortcut: String) {
        lastShortcut = currentShortcut
        chip.render(shortcut: currentShortcut)
    }

    func setCapturing(_ capturing: Bool) { chip.setCapturing(capturing) }

    func showMessage(_ text: String?, kind: MessageKind = .failure) {
        messageKind = (text == nil) ? nil : kind
        guard let text else { return messageLabel.clear() }
        messageLabel.show(text, tone: KeybindRow.tone(for: kind))
    }

    private static func tone(for kind: MessageKind) -> FormErrorLabel.Tone {
        switch kind {
        case .diagnostic, .notice: return .warning
        case .explanation: return .muted
        case .failure: return .destructive
        }
    }
    func focusChip() { window?.makeFirstResponder(chip) }

    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        chip.render(shortcut: lastShortcut)
    }

    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }
}
