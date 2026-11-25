import AppKit

struct ToastContent: Equatable {
    let variant: ToastVariant
    let title: String
    let titleTail: String?
    let message: String?
    let icon: String?
    let messageLabels: Set<String>

    init(
        variant: ToastVariant, title: String, titleTail: String? = nil, message: String?,
        icon: String? = nil, messageLabels: Set<String> = []
    ) {
        self.variant = variant
        self.title = title
        self.titleTail = titleTail
        self.message = message
        self.icon = icon
        self.messageLabels = messageLabels
    }
}

final class ToastView: ShadowCardView, ThemeReapplying {
    var onClose: (() -> Void)?
    var onDismissed: (() -> Void)?
    private(set) var isDismissing = false
    private let hasActions: Bool
    private let variant: ToastVariant
    private let glyph = NSImageView()
    private let titleLabel: NSTextField
    private let titleTailLabel: NSTextField?
    private var titleFloor: NSLayoutConstraint?
    private let messageLabel: NSTextField?
    private let messageLabels: Set<String>
    private var actionButtons: [AppButton] = []

    static let width: CGFloat = 300
    private static let textInset = ChromeMetrics.Spacing.s16
    private static let closeInset = ChromeMetrics.Spacing.s10
    private static let closeSide = ChromeMetrics.Height.sm
    private static let glyphGap = ChromeMetrics.Spacing.s10
    // The links' padding sits in the card's inset, so their text lines up with the message's.
    private static let linkRowInset = textInset - AppButton.horizontalPadding
    private static let glyphConfiguration = NSImage.SymbolConfiguration(
        pointSize: ChromeMetrics.Icon.md, weight: .semibold)
    private static let widestGlyph: CGFloat =
        ToastVariant.allCases.compactMap {
            NSImage(systemSymbolName: $0.defaultIcon, accessibilityDescription: nil)?
                .withSymbolConfiguration(glyphConfiguration)?.size.width
        }.max() ?? ChromeMetrics.Icon.md

    // Exposed so copy can be measured against the real wrap budget.
    static let messageMaxWidth: CGFloat = width - 2 * textInset
    static let titleMaxWidth: CGFloat =
        width - textInset - widestGlyph - glyphGap - glyphGap - closeSide - closeInset
    // A title up to this share of the row never gives way to its tail; a longer title yields first.
    private static let titleFloorShare: CGFloat = 0.55
    static let titleFont: NSFont = ChromeType.font(.body, weight: .medium)
    static let messageFont: NSFont = ChromeType.font(.small)
    private static var titleColor: NSColor { Theme.current.chrome.ink(.normal) }
    private static var messageColor: NSColor { Theme.current.chrome.ink(.muted) }

    convenience init(content: ToastContent) {
        self.init(content: content, actions: [])
    }

    private var shortcutSlots: [ShortcutSlot] = []

    init(
        content: ToastContent, actions: [ToastAction], showsClose: Bool = false
    ) {
        self.hasActions = !actions.isEmpty
        self.variant = content.variant
        self.titleLabel = NSTextField(labelWithString: content.title)
        self.titleTailLabel = content.titleTail.map { NSTextField(labelWithString: $0) }
        self.messageLabel = content.message.map { NSTextField(wrappingLabelWithString: $0) }
        self.messageLabels = content.messageLabels
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        CardChrome.apply(to: self, tier: .float)

        glyph.image = NSImage(
            systemSymbolName: content.icon ?? content.variant.defaultIcon, accessibilityDescription: content.title)
        glyph.symbolConfiguration = Self.glyphConfiguration
        glyph.contentTintColor = variant.role(in: Theme.current.chrome).nsColor
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = Self.titleFont
        titleLabel.textColor = Self.titleColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleTailLabel?.font = titleLabel.font
        titleTailLabel?.textColor = Self.titleColor
        titleTailLabel?.setContentCompressionResistancePriority(.init(rawValue: 999), for: .horizontal)
        titleTailLabel?.lineBreakMode = .byTruncatingMiddle
        if titleTailLabel != nil {
            let floor = titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
            floor.isActive = true
            titleFloor = floor
            updateTitleFloor()
        }

        restyleMessage()
        messageLabel?.preferredMaxLayoutWidth = Self.messageMaxWidth

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel] + (titleTailLabel.map { [$0] } ?? []))
        titleRow.orientation = .horizontal
        titleRow.spacing = 0
        let header = NSStackView(views: [glyph, titleRow, headerSpacer])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Self.glyphGap
        header.setCustomSpacing(0, after: titleRow)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.closeSide).isActive = true

        let isOneLine = messageLabel == nil
        actionButtons = Self.primaryLast(actions).map { Self.link(for: $0, alone: actions.count == 1) }
        if isOneLine {
            actionButtons.forEach(header.addArrangedSubview)
        }

        for resolve in actions.compactMap(\.shortcut) {
            let slot = ShortcutSlot(group: header, resolve: resolve)
            shortcutSlots.append(slot)
            slot.refresh()
        }

        if showsClose {
            let close = IconButton(
                symbol: "xmark", size: NSSize(width: Self.closeSide, height: Self.closeSide),
                pointSize: ChromeMetrics.Icon.xs,
                accessibilityLabel: "Dismiss"
            ) { [weak self] in self?.onClose?() }
            header.addArrangedSubview(close)
        }

        let lines = [header] + (messageLabel.map { [$0] } ?? [])
        let col = NSStackView(views: lines)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = ChromeMetrics.Spacing.s2
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)

        header.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        messageLabel?.widthAnchor.constraint(equalToConstant: Self.messageMaxWidth).isActive = true

        let trailingInset = showsClose ? Self.closeInset : Self.textInset
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            col.topAnchor.constraint(equalTo: topAnchor, constant: ChromeMetrics.Spacing.s8),
        ])
        guard !actionButtons.isEmpty, !isOneLine else {
            let bottomInset = isOneLine ? ChromeMetrics.Spacing.s8 : ChromeMetrics.Spacing.s12
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset).isActive = true
            return
        }
        let row = linkRow()
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.linkRowInset),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.textInset),
            row.topAnchor.constraint(equalTo: col.bottomAnchor, constant: ChromeMetrics.Spacing.s4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ChromeMetrics.Spacing.s8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func linkRow() -> NSView {
        let row = NSStackView(views: actionButtons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        return row
    }

    // The answer a toast asks for sits last in ink; every other action recedes before it.
    private static func primaryLast(_ actions: [ToastAction]) -> [ToastAction] {
        actions.filter { $0.kind != .primary } + actions.filter { $0.kind == .primary }
    }

    // Click-only: a toast never takes a key from the terminal.
    private static func link(for action: ToastAction, alone: Bool) -> AppButton {
        let variant: AppButton.Variant = alone || action.kind == .primary ? .link : .quietLink
        return AppButton(title: action.title, variant: variant, onTap: action.run)
    }

    private final class ShortcutSlot {
        private let group: NSStackView
        private let resolve: () -> String
        private var keycap: KeycapView?

        init(group: NSStackView, resolve: @escaping () -> String) {
            self.group = group
            self.resolve = resolve
        }

        func refresh() {
            let glyph = resolve()
            guard glyph != keycap?.shortcut else { return }
            let slot = keycap.flatMap { group.arrangedSubviews.firstIndex(of: $0) } ?? group.arrangedSubviews.count
            keycap.map { group.removeArrangedSubview($0) }
            keycap?.removeFromSuperview()
            keycap = nil
            guard !glyph.isEmpty else { return }
            let cap = KeycapView(shortcut: glyph)
            group.insertArrangedSubview(cap, at: slot)
            keycap = cap
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !hasActions { onClose?() }
    }

    // Ignored while animating out, so an outgoing card's Dismiss cannot fire against its replacement.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDismissing ? nil : super.hitTest(point)
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: self, tier: .float)
        glyph.contentTintColor = variant.role(in: Theme.current.chrome).nsColor
        titleLabel.textColor = Self.titleColor
        titleTailLabel?.textColor = Self.titleColor
        restyleMessage()
    }

    private func restyleMessage() {
        guard let messageLabel else { return }
        let text = NSMutableAttributedString()
        for (index, line) in messageLabel.stringValue.components(separatedBy: "\n").enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            let color = messageLabels.contains(line) ? Self.titleColor : Self.messageColor
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.messageFont, .foregroundColor: color]
            text.append(NSAttributedString(string: line, attributes: attributes))
        }
        messageLabel.attributedStringValue = text
    }

    var messageForTesting: NSAttributedString? { messageLabel?.attributedStringValue }

    var actionTitleColorsForTesting: [NSColor] {
        actionButtons.compactMap {
            $0.attributedTitle.length > 0
                ? $0.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                : nil
        }
    }

    var glyphTintForTesting: NSColor? { glyph.contentTintColor }
    var titleForTesting: String { titleLabel.stringValue }

    func setTitle(_ title: String) {
        guard titleLabel.stringValue != title else { return }
        titleLabel.stringValue = title
        updateTitleFloor()
    }

    private func updateTitleFloor() {
        let width = titleLabel.intrinsicContentSize.width
        titleFloor?.constant = width <= Self.messageMaxWidth * Self.titleFloorShare ? width : 0
    }

    func refreshShortcuts() {
        shortcutSlots.forEach { $0.refresh() }
    }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(self, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        Motion.springScaleFade(self, appearing: false, completion: completion)
    }
}
