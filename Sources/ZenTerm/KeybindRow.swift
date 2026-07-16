import AppKit

/// One Keybinds row: the action label and its chord as a focusable `KeybindChip`. The chip is the
/// row's single focus stop — Return / Space / click begins capture, Backspace reverts to default,
/// Up/Down move between rows, Left exits to the nav, Esc closes the card. An inline message under the
/// row carries validation / conflict text.
final class KeybindRow: NSView {
    let action: KeyInterceptor.ReservedChord
    let chip = KeybindChip()
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it in place.
    private let titleLabel: NSTextField
    private let messageLabel = NSTextField(labelWithString: "")
    /// The last shortcut string handed to `render` — kept so `reapplyTheme()` can re-render the
    /// chip (rebuilding its `KeycapView` glyphs against the new theme) without the section having
    /// to resupply it.
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
    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }
    func focusChip() { window?.makeFirstResponder(chip) }

    /// Re-apply the live chrome colors after a config change — no relaunch. Matches the exact
    /// roles set at construction: title foreground, message destructive. Re-renders the chip with
    /// the last-known shortcut so its `KeycapView` glyphs (built fresh against `Theme.current` on
    /// every render) pick up the new theme too, and recolors the chip's own box (fill/border),
    /// which `render(shortcut:)` never touches.
    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        chip.render(shortcut: lastShortcut)
        chip.reapplyTheme()
    }

    /// Test hook: the inline message as actually rendered — nil when the label is hidden. Reads the
    /// label rather than a backing property, so a test can't pass while the row shows nothing.
    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }
}
