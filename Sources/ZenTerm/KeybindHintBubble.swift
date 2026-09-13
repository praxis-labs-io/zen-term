import AppKit

final class KeybindHintBubble: ShadowCardView {
    private static let width: CGFloat = 220
    private static let insets: CGFloat = 28
    private static let resetSlot: CGFloat = 34 + 8

    static func inputWidth(withReset: Bool) -> CGFloat {
        width - insets - (withReset ? resetSlot : 0)
    }

    private let previewHost = NSView()
    private let statusHost = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    /// Hidden until a host asks: the tool-float form shares this popover and has no defaults.
    private lazy var resetButton = IconButton(
        symbol: "arrow.uturn.backward", size: NSSize(width: 34, height: 34), pointSize: 13,
        accessibilityLabel: "Reset to default", restsFilled: true
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
        badge.layer?.backgroundColor =
            Theme.current.chrome.tint(Theme.current.chrome.accent, alpha: ChromeTheme.badgeTint).cgColor
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

        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.backgroundColor = Theme.current.chrome.fill(.rest).cgColor
        previewBox.layer?.borderWidth = 1.5
        previewBox.layer?.borderColor = Theme.current.chrome.accent.nsColor.cgColor
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewHost)

        errorLabel.font = .systemFont(ofSize: 10, weight: .medium)
        errorLabel.textColor = Theme.current.chrome.destructive.nsColor
        errorLabel.alignment = .center
        errorLabel.preferredMaxLayoutWidth = Self.inputWidth(withReset: true)
        errorLabel.isHidden = true

        previewBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        let inputRow = NSStackView(views: [previewBox, resetButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        inputRow.distribution = .fill

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
            errorLabel.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
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

        resetButton.isHidden = true
        setPreview("")
        showInstructions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setPreview(_ glyph: String) {
        previewHost.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        if glyph.isEmpty {
            let label = NSTextField(labelWithString: "Press keys…")
            label.font = .systemFont(ofSize: 12)
            label.textColor = Theme.current.chrome.ink(.muted)
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

    var inputWidthForTesting: CGFloat { previewHost.superview?.frame.width ?? 0 }

    static var widthForTesting: CGFloat { width }

    var previewedChordForTesting: String? {
        (previewHost.subviews.first as? KeycapView)?.shortcut
    }

    func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
    }
    func clearError() { errorLabel.isHidden = true }

    func setCanResetToDefault(_ canReset: Bool) { resetButton.isHidden = !canReset }

    func showInstructions() {
        let cancel = Self.muted("to cancel")
        let keys = NSStackView(views: [
            Self.keyCap("esc"), cancel, Self.keyCap("del"), Self.muted("to remove"),
        ])
        keys.orientation = .horizontal
        keys.alignment = .centerY
        keys.spacing = 5
        keys.setCustomSpacing(12, after: cancel)
        setStatus(keys)
    }

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

    private static func keyCap(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = Theme.current.chrome.ink(.subtle)
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        box.layer?.backgroundColor = Theme.current.chrome.fill(.rest).cgColor
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
        label.textColor = Theme.current.chrome.ink(.muted)
        return label
    }
}
