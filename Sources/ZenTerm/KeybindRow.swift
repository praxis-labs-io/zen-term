import AppKit

/// One Keybinds row: the action label and its chord as a focusable `KeybindChip`. The chip is the
/// row's single focus stop — Return / Space / click begins capture, Backspace removes the shortcut,
/// Up/Down move between rows, Left exits to the nav, Esc closes the card. An inline message under the
/// row carries validation / conflict text.
final class KeybindRow: NSView {
    /// Why the row is showing a message, which decides both its ink and who may clear it.
    enum MessageKind: Equatable {
        /// A problem in the config file: a bind on a menu chord, a chord this keyboard can't
        /// type. Owned by the section's refresh: it's true for as long as the config says so.
        case diagnostic
        /// A chord conflict: a line in the config gave this row's chord to something else, and the
        /// row offers Accept and Revert beside this. Muted rather than warning-toned, because the
        /// config is doing what it says and the answer is right there (ZEN-368).
        case explanation
        /// A side effect of an edit the user just made elsewhere in the card — this row's chord was
        /// taken by another action's reset. Transient: the next refresh clears it.
        case notice
        /// A failure of something the user just did (a config write that didn't land). Outlives a
        /// refresh, because a refresh isn't what resolves it — only a write that lands does.
        case failure
    }

    let action: KeyInterceptor.ReservedChord
    let chip = KeybindChip()
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it in place.
    private let titleLabel: NSTextField
    private let messageLabel = NSTextField(labelWithString: "")
    private(set) var messageKind: MessageKind?
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

    /// Show (or clear, with nil) the row's inline message. A `.diagnostic` reads as a warning — the
    /// config is doing what it says, just not what the user wanted — while a `.failure` reads
    /// destructive. Rendering a working config in the same red as "couldn't write config" would
    /// teach the user to read both as breakage.
    func showMessage(_ text: String?, kind: MessageKind = .failure) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
        messageKind = (text == nil) ? nil : kind
        messageLabel.textColor = KeybindRow.ink(for: messageKind)
    }

    private static func ink(for kind: MessageKind?) -> NSColor {
        switch kind {
        case .diagnostic, .notice: return Theme.current.chrome.warning.nsColor
        case .explanation: return Theme.current.chrome.ink(alpha: 0.45)
        case .failure, nil: return Theme.current.chrome.destructive.nsColor
        }
    }
    func focusChip() { window?.makeFirstResponder(chip) }

    /// Re-apply the live chrome colors after a config change — no relaunch. Matches the exact
    /// roles set at construction: title foreground, message destructive. Re-renders the chip with
    /// the last-known shortcut so its `KeycapView` glyphs (built fresh against `Theme.current` on
    /// every render) pick up the new theme too, and recolors the chip's own box (fill/border),
    /// which `render(shortcut:)` never touches.
    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        messageLabel.textColor = KeybindRow.ink(for: messageKind)
        chip.render(shortcut: lastShortcut)
        chip.reapplyTheme()
    }

    /// Test hook: the inline message as actually rendered — nil when the label is hidden. Reads the
    /// label rather than a backing property, so a test can't pass while the row shows nothing.
    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }
}
