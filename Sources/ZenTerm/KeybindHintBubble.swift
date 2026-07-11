import AppKit

/// The chord-capture popover — built on the same card chrome as a toast (`FloatShadow` background +
/// hairline edge + drop shadow, a tinted icon badge, a title and body column). Shown by the section
/// beside a capturing keybind chip: a title, an example chord, and the cancel / remove keys.
final class KeybindHintBubble: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.applyShadow(to: self)

        let accent = Theme.current.chrome.info.nsColor

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Record a shortcut")
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        let title = NSTextField(labelWithString: "Record a shortcut")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.current.chrome.foreground.nsColor

        let example = KeycapView(shortcut: "⌘P")

        let instructions = NSStackView(views: [
            Self.keyCap("esc"), Self.muted("to cancel"), Self.muted("·"),
            Self.keyCap("del"), Self.muted("to remove"),
        ])
        instructions.orientation = .horizontal
        instructions.alignment = .centerY
        instructions.spacing = 5

        let col = NSStackView(views: [title, example, instructions])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8

        let root = NSStackView(views: [badge, col])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A small inline key chip (`esc`, `del`) — a faint rounded box with muted monospaced text.
    private static func keyCap(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = Theme.current.chrome.ink(alpha: 0.7)
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.10).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        return box
    }

    private static func muted(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.current.chrome.ink(alpha: 0.5)
        return label
    }
}
