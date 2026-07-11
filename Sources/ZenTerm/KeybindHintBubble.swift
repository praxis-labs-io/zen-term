import AppKit

/// The chord-capture popover — built on the toast card chrome (`FloatShadow` background + hairline
/// edge + drop shadow). A header row (tinted keyboard badge + title), a full-width muted preview box
/// that shows the chord live as it's typed, and a status line that starts as the cancel/remove keys
/// and is replaced with a validation warning or a success message. Shown by the section beside a
/// capturing keybind chip.
final class KeybindHintBubble: NSView {
    private static let width: CGFloat = 300

    private let previewHost = NSView()
    private let statusHost = NSView()

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

        let header = NSStackView(views: [badge, title])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        // Full-width muted input-looking box holding the live chord preview.
        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.06).cgColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewHost)

        statusHost.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [header, previewBox, statusHost])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 14
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            previewBox.heightAnchor.constraint(equalToConstant: 34),
            previewBox.widthAnchor.constraint(equalTo: col.widthAnchor),
            previewHost.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 10),
            previewHost.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -10),
            previewHost.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            statusHost.widthAnchor.constraint(equalTo: col.widthAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            col.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        setPreview("")
        showInstructions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Show the chord being typed (its display glyph) in the preview box, or a placeholder when empty.
    func setPreview(_ glyph: String) {
        previewHost.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        if glyph.isEmpty {
            let label = NSTextField(labelWithString: "Press keys…")
            label.font = .systemFont(ofSize: 12)
            label.textColor = Theme.current.chrome.ink(alpha: 0.4)
            content = label
        } else {
            content = KeycapView(shortcut: glyph, showsBackground: false)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: previewHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
        ])
    }

    /// The default status line: the cancel / remove keys.
    func showInstructions() {
        let row = NSStackView(views: [
            Self.keyCap("esc"), Self.muted("to cancel"), Self.muted("·"),
            Self.keyCap("del"), Self.muted("to remove"),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        setStatus(row)
    }

    func showWarning(_ text: String) { setStatus(message(text, color: Theme.current.chrome.destructive.nsColor)) }
    func showSuccess(_ text: String) { setStatus(message(text, color: Theme.current.chrome.accent.nsColor)) }

    private func setStatus(_ view: NSView) {
        statusHost.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        statusHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: statusHost.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: statusHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: statusHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: statusHost.bottomAnchor),
        ])
    }

    private func message(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        label.preferredMaxLayoutWidth = Self.width - 28
        return label
    }

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
