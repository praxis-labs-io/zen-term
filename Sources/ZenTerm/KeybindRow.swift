import AppKit

/// One Keybinds row: the action label and its chord as a focusable `KeybindChip`. The chip is the
/// row's single focus stop — Return / Space / click begins capture, Backspace reverts to default,
/// Up/Down move between rows, Left exits to the nav, Esc closes the card. An inline message under the
/// row carries validation / conflict text.
final class KeybindRow: NSView {
    let action: KeyInterceptor.ReservedChord
    let chip = KeybindChip()
    private let messageLabel = NSTextField(labelWithString: "")

    init(action: KeyInterceptor.ReservedChord, title: String) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

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

    func render(currentShortcut: String) { chip.render(shortcut: currentShortcut) }
    func setCapturing(_ capturing: Bool) { chip.setCapturing(capturing) }
    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }
    func focusChip() { window?.makeFirstResponder(chip) }
}
