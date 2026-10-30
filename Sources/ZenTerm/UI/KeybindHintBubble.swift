import AppKit

final class KeybindHintBubble: ShadowCardView, ThemeReapplying {
    private static let width: CGFloat = 220
    private static let padding = ChromeMetrics.Spacing.s12
    private static let resetSlot = ChromeMetrics.Height.control + ChromeMetrics.Spacing.s8
    private static let gap = ChromeMetrics.Spacing.s6

    static func inputWidth(withReset: Bool) -> CGFloat {
        width - padding - padding - (withReset ? resetSlot : 0)
    }

    private let previewHost = NSView()
    private let previewBox = NSView()
    private let badge = IconBadge(
        symbol: "keyboard", accessibilityDescription: "Record a shortcut", size: .regular,
        role: { $0.accent })
    private let title = NSTextField(labelWithString: "Record a shortcut")
    private var previewGlyph = ""
    private var successText: String?
    private let statusHost = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    /// Hidden until a host asks: the tool-float form shares this popover and has no defaults.
    private lazy var resetButton = IconButton(
        symbol: "arrow.uturn.backward",
        size: NSSize(width: ChromeMetrics.Height.control, height: ChromeMetrics.Height.control),
        pointSize: ChromeMetrics.Icon.sm,
        accessibilityLabel: "Reset to default", restsFilled: true
    ) { [weak self] in self?.onResetToDefault?() }
    var onResetToDefault: (() -> Void)?
    private var originPins: (leading: NSLayoutConstraint, edge: NSLayoutConstraint)?
    private weak var anchor: NSView?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        CardChrome.apply(to: self, tier: .overlay)

        title.font = ChromeType.font(.body, weight: .semibold)

        let header = NSStackView(views: [badge, title])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = ChromeMetrics.Spacing.s10

        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = ChromeMetrics.Radius.control
        previewBox.layer?.borderWidth = ChromeMetrics.Border.width
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewHost)

        errorLabel.font = ChromeType.font(.caption, weight: .medium)
        errorLabel.alignment = .center
        errorLabel.preferredMaxLayoutWidth = Self.inputWidth(withReset: true)
        errorLabel.isHidden = true

        previewBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        let inputRow = NSStackView(views: [previewBox, resetButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = ChromeMetrics.Spacing.s8
        inputRow.distribution = .fill

        let previewGroup = NSStackView(views: [inputRow, errorLabel])
        previewGroup.orientation = .vertical
        previewGroup.alignment = .leading
        previewGroup.spacing = ChromeMetrics.Spacing.s4

        statusHost.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [header, previewGroup, statusHost])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = ChromeMetrics.Spacing.s12
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            previewGroup.widthAnchor.constraint(equalTo: col.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: previewGroup.widthAnchor),
            previewBox.heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control),
            errorLabel.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            previewHost.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            previewHost.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            previewHost.leadingAnchor.constraint(
                greaterThanOrEqualTo: previewBox.leadingAnchor, constant: ChromeMetrics.Spacing.s10),
            previewHost.trailingAnchor.constraint(
                lessThanOrEqualTo: previewBox.trailingAnchor, constant: -ChromeMetrics.Spacing.s10),
            statusHost.widthAnchor.constraint(equalTo: col.widthAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.s12),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.s12),
            col.topAnchor.constraint(equalTo: topAnchor, constant: ChromeMetrics.Spacing.s12),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ChromeMetrics.Spacing.s12),
        ])

        resetButton.isHidden = true
        setPreview("")
        paintColors()
        showInstructions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var badgeFillForTesting: CGColor? { badge.fillForTesting }
    var badgeIconTintForTesting: NSColor? { badge.iconTintForTesting }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        originPins = nil
    }

    func place(near anchor: NSView) {
        self.anchor = anchor
        reposition()
    }

    private func reposition() {
        guard let anchor, let host = superview else { return }
        let pins = originPins ?? makeOriginPins(in: host)
        originPins = pins
        layoutSubtreeIfNeeded()
        let origin = HoverCardView.placementFrame(
            size: fittingSize, anchor: anchor.convert(anchor.bounds, to: host), in: host, gap: Self.gap
        ).origin
        pins.leading.constant = origin.x
        pins.edge.constant = host.isFlipped ? origin.y : -origin.y
        host.layoutSubtreeIfNeeded()
    }

    private func makeOriginPins(in host: NSView) -> (leading: NSLayoutConstraint, edge: NSLayoutConstraint) {
        let pins = (
            leading: leadingAnchor.constraint(equalTo: host.leadingAnchor),
            edge: host.isFlipped
                ? topAnchor.constraint(equalTo: host.topAnchor) : bottomAnchor.constraint(equalTo: host.bottomAnchor)
        )
        NSLayoutConstraint.activate([pins.leading, pins.edge])
        return pins
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: self, tier: .overlay)
        paintColors()
        setPreview(previewGlyph)
        if let successText { showSuccess(successText) } else { showInstructions() }
    }

    private func paintColors() {
        let chrome = Theme.current.chrome
        title.textColor = chrome.ink(.normal)
        previewBox.layer?.backgroundColor = chrome.fill(.rest).cgColor
        previewBox.layer?.borderColor = chrome.accent.nsColor.cgColor
        errorLabel.textColor = chrome.destructive.nsColor
    }

    func setPreview(_ glyph: String) {
        previewGlyph = glyph
        previewHost.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        if glyph.isEmpty {
            let label = NSTextField(labelWithString: "Press keys…")
            label.font = ChromeType.font(.small)
            label.textColor = Theme.current.chrome.ink(.muted)
            content = label
        } else {
            content = KeycapView(shortcut: glyph, style: .plain)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: previewHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
        ])
        reposition()
    }

    var inputWidthForTesting: CGFloat { previewHost.superview?.frame.width ?? 0 }

    static var widthForTesting: CGFloat { width }

    var previewedChordForTesting: String? {
        (previewHost.subviews.first as? KeycapView)?.shortcut
    }

    func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
        reposition()
    }

    func clearError() {
        errorLabel.isHidden = true
        reposition()
    }

    func setCanResetToDefault(_ canReset: Bool) {
        resetButton.isHidden = !canReset
        reposition()
    }

    func showInstructions() {
        successText = nil
        let cancel = Self.muted("to cancel")
        let keys = NSStackView(views: [
            Self.keyCap("esc"), cancel, Self.keyCap("del"), Self.muted("to remove"),
        ])
        keys.orientation = .horizontal
        keys.alignment = .centerY
        keys.spacing = ChromeMetrics.Spacing.s4
        keys.setCustomSpacing(ChromeMetrics.Spacing.s12, after: cancel)
        setStatus(keys)
    }

    func showSuccess(_ text: String) {
        successText = text
        let label = NSTextField(labelWithString: text)
        label.font = ChromeType.font(.small, weight: .medium)
        label.textColor = Theme.current.chrome.positive.nsColor
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
        reposition()
    }

    private static func keyCap(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeType.font(.caption, weight: .medium, face: .mono)
        label.textColor = Theme.current.chrome.ink(.subtle)
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = ChromeMetrics.Radius.control
        box.layer?.backgroundColor = Theme.current.chrome.fill(.rest).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: ChromeMetrics.Spacing.s4),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -ChromeMetrics.Spacing.s4),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: ChromeMetrics.Spacing.s2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -ChromeMetrics.Spacing.s2),
        ])
        return box
    }

    private static func muted(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeType.font(.caption)
        label.textColor = Theme.current.chrome.ink(.muted)
        return label
    }
}
