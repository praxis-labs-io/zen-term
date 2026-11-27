import AppKit

final class KeybindHintBubble: ShadowCardView, ThemeReapplying {
    private static let insets = ChromeMetrics.Spacing.modalInsets
    private static let gap = ChromeMetrics.Spacing.s6

    private let previewHost = NSView()
    private let previewBox = NSView()
    private let header = ModalHeader(title: "Record a shortcut")
    private var previewGlyph = ""
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var isShowingError = false
    // The input row runs the hints' exact length; a reset button takes its room from the input.
    private let footer = HintFooter(
        [.init(keys: "⌫", label: "Remove"), .init(keys: "⎋", label: "Cancel")], inset: insets.left, side: .leading)
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

        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = ChromeMetrics.Radius.control
        previewBox.layer?.borderWidth = ChromeMetrics.Border.width
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewHost)

        noteLabel.font = ChromeType.font(.caption, weight: .medium)
        noteLabel.alignment = .center
        noteLabel.preferredMaxLayoutWidth = footer.hintsWidth
        noteLabel.isHidden = true

        previewBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        let inputRow = NSStackView(views: [previewBox, resetButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = ChromeMetrics.Spacing.s8
        inputRow.distribution = .fill

        let previewGroup = NSStackView(views: [inputRow, noteLabel])
        previewGroup.orientation = .vertical
        previewGroup.alignment = .leading
        previewGroup.spacing = ChromeMetrics.Spacing.s4

        let content = NSStackView(views: [header, previewGroup])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = ChromeMetrics.Spacing.modalSectionGap
        content.edgeInsets = Self.insets
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSStackView(views: [content, footer])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 0
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: card.widthAnchor),
            footer.widthAnchor.constraint(equalTo: card.widthAnchor),
            widthAnchor.constraint(equalToConstant: Self.insets.left + footer.hintsWidth + Self.insets.right),
            inputRow.widthAnchor.constraint(equalToConstant: footer.hintsWidth),
            header.widthAnchor.constraint(equalTo: inputRow.widthAnchor),
            previewGroup.widthAnchor.constraint(equalTo: inputRow.widthAnchor),
            previewBox.heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control),
            noteLabel.widthAnchor.constraint(equalTo: previewBox.widthAnchor),
            previewHost.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            previewHost.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            previewHost.leadingAnchor.constraint(
                greaterThanOrEqualTo: previewBox.leadingAnchor, constant: ChromeMetrics.Spacing.s10),
            previewHost.trailingAnchor.constraint(
                lessThanOrEqualTo: previewBox.trailingAnchor, constant: -ChromeMetrics.Spacing.s10),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        resetButton.isHidden = true
        setPreview("")
        paintColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
    }

    private func paintColors() {
        let chrome = Theme.current.chrome
        previewBox.layer?.backgroundColor = chrome.fill(.rest).cgColor
        previewBox.layer?.borderColor = chrome.accent.nsColor.cgColor
        noteLabel.textColor = isShowingError ? chrome.destructive.nsColor : chrome.positive.nsColor
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

    var hintsWidthForTesting: CGFloat { footer.hintsWidth }

    var previewedChordForTesting: String? {
        (previewHost.subviews.first as? KeycapView)?.shortcut
    }

    func showError(_ text: String) {
        isShowingError = true
        showNote(text)
    }

    func clearError() {
        guard isShowingError else { return }
        isShowingError = false
        noteLabel.isHidden = true
        reposition()
    }

    func setCanResetToDefault(_ canReset: Bool) {
        resetButton.isHidden = !canReset
        reposition()
    }

    func showInstructions() {
        guard !isShowingError else { return }
        noteLabel.isHidden = true
        reposition()
    }

    func showSuccess(_ text: String) {
        isShowingError = false
        showNote(text)
    }

    var hintsForTesting: [HintFooter.Hint] { footer.hints }

    private func showNote(_ text: String) {
        noteLabel.stringValue = text
        noteLabel.isHidden = false
        paintColors()
        reposition()
    }
}
