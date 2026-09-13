import AppKit

final class KeybindRow: NSView {
    enum MessageKind: Equatable {
        case diagnostic
        case explanation
        case notice
        case failure
    }

    let action: KeyInterceptor.ReservedChord
    let chip = KeybindChip()
    private let titleLabel: NSTextField
    private let messageLabel = NSTextField(labelWithString: "")
    private(set) var messageKind: MessageKind?
    private var lastShortcut = ""

    init(action: KeyInterceptor.ReservedChord, title: String) {
        self.action = action

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel = label

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [label, spacer, chip])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        messageLabel.isHidden = true

        let stack = NSStackView(views: [controls, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(currentShortcut: String) {
        lastShortcut = currentShortcut
        chip.render(shortcut: currentShortcut)
    }

    func setCapturing(_ capturing: Bool) { chip.setCapturing(capturing) }

    func showMessage(_ text: String?, kind: MessageKind = .failure) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
        messageKind = (text == nil) ? nil : kind
        messageLabel.textColor = KeybindRow.ink(for: messageKind)
    }

    private static func ink(for kind: MessageKind?) -> NSColor {
        switch kind {
        case .diagnostic, .notice: return Theme.current.chrome.warning.nsColor
        case .explanation: return Theme.current.chrome.ink(.muted)
        case .failure, nil: return Theme.current.chrome.destructive.nsColor
        }
    }
    func focusChip() { window?.makeFirstResponder(chip) }

    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        messageLabel.textColor = KeybindRow.ink(for: messageKind)
        chip.render(shortcut: lastShortcut)
        chip.reapplyTheme()
    }

    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }
}
