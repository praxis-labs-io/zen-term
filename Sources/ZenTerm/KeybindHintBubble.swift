import AppKit

/// The chord-capture popover — built on the toast card chrome (`FloatShadow` background + hairline
/// edge + drop shadow). A header row (tinted keyboard badge + title), a full-width muted preview box
/// that shows the chord live (centered) with a small red validation line tucked beneath it, and a
/// status line (the command keys, replaced by a success message on save). The input carries the
/// accent ring while it listens, with a reset icon beside it. Shown by the section next to a
/// capturing keybind chip.
final class KeybindHintBubble: ShadowCardView {
    private static let width: CGFloat = 220

    private let previewHost = NSView()
    private let statusHost = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    /// Reset the row to its built-in chord, beside the input it acts on. Hidden on a row already at
    /// its default, where it would be a control that does nothing.
    private lazy var resetButton = IconButton(
        symbol: "arrow.uturn.backward", accessibilityLabel: "Reset to default"
    ) { [weak self] in self?.onResetToDefault?() }
    var onResetToDefault: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.applyShadow(to: self)

        let accent = Theme.current.chrome.accent.nsColor

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

        // Full-width muted input-looking box holding the live chord preview, centered.
        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.06).cgColor
        // The accent ring says the input is listening, the same signal a focused chip carries.
        previewBox.layer?.borderWidth = 1.5
        previewBox.layer?.borderColor = Theme.current.chrome.accent.nsColor.cgColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewHost)

        // Small red validation line, tucked just under the preview; collapsed until there's an error.
        errorLabel.font = .systemFont(ofSize: 10, weight: .medium)
        errorLabel.textColor = Theme.current.chrome.destructive.nsColor
        errorLabel.preferredMaxLayoutWidth = Self.width - 28
        errorLabel.isHidden = true

        // The reset sits beside the input rather than under it: it acts on the same thing the input
        // is showing, and a row of its own would read as a third command next to esc and del.
        let inputRow = NSStackView(views: [previewBox, resetButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8

        let previewGroup = NSStackView(views: [inputRow, errorLabel])
        previewGroup.orientation = .vertical
        previewGroup.alignment = .leading
        previewGroup.spacing = 4

        statusHost.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [header, previewGroup, statusHost])
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
            previewGroup.widthAnchor.constraint(equalTo: col.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: previewGroup.widthAnchor),
            previewBox.heightAnchor.constraint(equalToConstant: 34),
            previewHost.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            previewHost.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            previewHost.leadingAnchor.constraint(greaterThanOrEqualTo: previewBox.leadingAnchor, constant: 10),
            previewHost.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -10),
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

    /// Show the chord being typed (its display glyph) centered in the preview box, or a placeholder.
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

    /// Test hook: the chord the input is drawing, or nil when it shows the listening placeholder.
    /// Reads the rendered subview rather than a stored string, so a test can't pass while the box
    /// actually shows something else.
    var previewedChordForTesting: String? {
        (previewHost.subviews.first as? KeycapView)?.shortcut
    }

    /// A small red validation line under the preview; the status controls below stay put.
    func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
    }
    func clearError() { errorLabel.isHidden = true }

    /// Whether the row this popover is over can be put back. The reset is hidden on a row already
    /// at its default, where it would be a control that does nothing.
    func setCanResetToDefault(_ canReset: Bool) { resetButton.isHidden = !canReset }

    /// The default status line: the two command keys. Reset is the icon beside the input, not a
    /// third key here, because it acts on what the input is showing rather than on the recording.
    func showInstructions() {
        let cancel = Self.muted("to cancel")
        let keys = NSStackView(views: [
            Self.keyCap("esc"), cancel, Self.keyCap("del"), Self.muted("to remove"),
        ])
        keys.orientation = .horizontal
        keys.alignment = .centerY
        keys.spacing = 5
        keys.setCustomSpacing(12, after: cancel)  // gap between the two groups, no dot separator
        setStatus(keys)
    }

    /// Replace the status line with a success message before the popover closes.
    func showSuccess(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.current.chrome.accent.nsColor
        setStatus(label)
    }

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

    /// A small inline key chip (`esc`, `del`): a faint rounded box with muted monospaced text.
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
