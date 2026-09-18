import AppKit

struct ToastContent: Equatable {
    let variant: ToastVariant
    let title: String
    /// Follows `title` and never truncates, so a long title gives way before it does.
    let titleTail: String?
    let message: String
    let icon: String?

    init(
        variant: ToastVariant, title: String, titleTail: String? = nil, message: String,
        icon: String? = nil
    ) {
        self.variant = variant
        self.title = title
        self.titleTail = titleTail
        self.message = message
        self.icon = icon
    }
}

final class ToastView: ShadowCardView {
    var onClose: (() -> Void)?
    var onDismissed: (() -> Void)?
    private(set) var isDismissing = false
    private let hasActions: Bool
    // A non-modal toast must never take first responder, or it steals terminal input.
    private let gatesFocus: Bool
    private let confirmAction: (() -> Void)?
    // Not what the dismiss chords run: on a keybind-conflict card it is Revert, which rewrites the config.
    private let cancelAction: (() -> Void)?
    private let variant: ToastVariant
    private let titleLabel: NSTextField
    private let titleTailLabel: NSTextField?
    private let messageLabel: NSTextField
    private var closeButton: IconButton?
    private var actionButtons: [AppButton] = []
    private let badgeFill = NSView()
    private let badgeIcon = NSImageView()

    private static let width: CGFloat = 300

    // Exposed so copy can be measured against the real wrap budget.
    static let messageMaxWidth: CGFloat = 236
    static let messageFont: NSFont = .systemFont(ofSize: 12)
    private static var titleColor: NSColor { Theme.current.chrome.foreground.nsColor }
    private static var messageColor: NSColor { Theme.current.chrome.muted.nsColor }

    convenience init(content: ToastContent) {
        self.init(content: content, actions: [])
    }

    private var shortcutSlots: [ShortcutSlot] = []

    init(
        content: ToastContent, actions: [ToastAction], armsKeys: Bool = true,
        showsClose: Bool = false
    ) {
        self.hasActions = !actions.isEmpty
        self.gatesFocus = armsKeys && !actions.isEmpty
        self.confirmAction = actions.first { $0.kind != .cancel }?.run
        self.cancelAction = actions.first { $0.kind == .cancel }?.run
        self.variant = content.variant
        self.titleLabel = NSTextField(labelWithString: content.title)
        self.titleTailLabel = content.titleTail.map { NSTextField(labelWithString: $0) }
        self.messageLabel = NSTextField(wrappingLabelWithString: content.message)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.applyShadow(to: self)

        badgeFill.wantsLayer = true
        badgeFill.layer?.cornerRadius = 7
        badgeFill.translatesAutoresizingMaskIntoConstraints = false
        badgeIcon.image = NSImage(
            systemSymbolName: content.icon ?? content.variant.defaultIcon,
            accessibilityDescription: content.title)
        badgeIcon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        badgeFill.addSubview(badgeIcon)
        applyBadgeTheme()

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Self.titleColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleTailLabel?.font = titleLabel.font
        titleTailLabel?.textColor = Self.titleColor
        titleTailLabel?.setContentCompressionResistancePriority(.required, for: .horizontal)

        messageLabel.font = Self.messageFont
        messageLabel.textColor = Self.messageColor
        messageLabel.preferredMaxLayoutWidth = Self.messageMaxWidth

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel] + (titleTailLabel.map { [$0] } ?? []))
        titleRow.orientation = .horizontal
        titleRow.spacing = 0
        let header = NSStackView(views: [titleRow, headerSpacer])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let col = NSStackView(views: [header, messageLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        messageLabel.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        header.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        for resolve in actions.compactMap(\.shortcut) {
            let slot = ShortcutSlot(group: header, resolve: resolve)
            shortcutSlots.append(slot)
            slot.refresh()
        }

        if showsClose {
            let close = IconButton(
                symbol: "xmark", size: NSSize(width: 20, height: 20), pointSize: 10,
                accessibilityLabel: "Dismiss"
            ) { [weak self] in self?.onClose?() }
            header.addArrangedSubview(close)
            closeButton = close
        }

        if !actions.isEmpty {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            actionButtons = actions.map(Self.button(for:))
            let row = NSStackView(views: actionButtons + [spacer])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            col.addArrangedSubview(row)
            col.setCustomSpacing(9, after: messageLabel)
            row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }

        let root = NSStackView(views: [badgeFill, col])
        root.orientation = .horizontal
        root.alignment = .top
        root.distribution = .fill
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            badgeFill.widthAnchor.constraint(equalToConstant: 28),
            badgeFill.heightAnchor.constraint(equalToConstant: 28),
            badgeIcon.centerXAnchor.constraint(equalTo: badgeFill.centerXAnchor),
            badgeIcon.centerYAnchor.constraint(equalTo: badgeFill.centerYAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Click-only: a `keyEquivalent` answers only when the traversal reaches the button, so the card owns Return and Esc.
    private static func button(for action: ToastAction) -> AppButton {
        let variant: AppButton.Variant
        switch action.kind {
        case .primary: variant = .primary
        case .destructive: variant = .destructive
        case .cancel: variant = .secondary
        }
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
            keycap.map { group.removeArrangedSubview($0) }
            keycap?.removeFromSuperview()
            keycap = nil
            guard !glyph.isEmpty else { return }
            let cap = KeycapView(shortcut: glyph)
            group.addArrangedSubview(cap)
            keycap = cap
        }

        func reapplyTheme() { keycap?.reapplyTheme() }
    }

    override var acceptsFirstResponder: Bool { gatesFocus }

    // Both entry points: this misses bare keys under some focused hosts, and `keyDown` needs first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if answer(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !answer(event) { super.keyDown(with: event) }
    }

    // Bare keys only, or an unbound ⌥⏎ would quit the app.
    private func answer(_ event: NSEvent) -> Bool {
        guard gatesFocus, !isDismissing, KeyboardFocus.isUnmodified(event) else { return false }
        if KeyboardFocus.isReturn(event) {
            confirmAction?()
            return confirmAction != nil
        }
        if KeyboardFocus.key(for: event) == .delete {
            cancelAction?()
            return cancelAction != nil
        }
        guard let cancelAction else { return false }
        return ModalEscape.handle(event, in: window, dismissing: isDismissing, close: cancelAction)
    }

    override func mouseDown(with event: NSEvent) {
        if !hasActions { onClose?() }
    }

    // Ignored while animating out, so an outgoing card's Dismiss cannot fire against its replacement.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDismissing ? nil : super.hitTest(point)
    }

    func reapplyTheme() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderColor = FloatShadow.edge.cgColor
        titleLabel.textColor = Self.titleColor
        titleTailLabel?.textColor = Self.titleColor
        messageLabel.textColor = Self.messageColor
        shortcutSlots.forEach { $0.reapplyTheme() }
        closeButton?.reapplyTheme()
        actionButtons.forEach { $0.reapplyTheme() }
        applyBadgeTheme()
    }

    private func applyBadgeTheme() {
        let chrome = Theme.current.chrome
        let role = variant.role(in: chrome)
        badgeFill.layer?.backgroundColor = chrome.tint(role, alpha: ChromeTheme.badgeTint).cgColor
        badgeIcon.contentTintColor = role.nsColor
    }

    var actionTitleColorsForTesting: [NSColor] {
        actionButtons.compactMap {
            $0.attributedTitle.length > 0
                ? $0.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                : nil
        }
    }

    var badgeFillForTesting: CGColor? { badgeFill.layer?.backgroundColor }
    var badgeIconTintForTesting: NSColor? { badgeIcon.contentTintColor }

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
