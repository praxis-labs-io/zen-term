import AppKit

/// One toast's content: a tone (`variant`), a terse title, a description, and an optional
/// icon override (defaults to the variant's glyph).
struct ToastContent: Equatable {
    let variant: ToastVariant
    let title: String
    let message: String
    let icon: String?

    init(variant: ToastVariant, title: String, message: String, icon: String? = nil) {
        self.variant = variant
        self.title = title
        self.message = message
        self.icon = icon
    }
}

/// A transient notification card: a tinted icon badge, a title with a close affordance, a
/// muted description, and an optional small actions row — on the shared overlay-card chrome
/// (`FloatShadow` bg + hairline edge + drop shadow). Fixed width; springs in/out on `Motion`.
/// The `ToastPresenter` owns placement (top-right) and lifetime.
final class ToastView: NSView {
    /// The "×" (and, for a passive toast, a body click) fires this — the presenter dismisses,
    /// or a confirm cancels.
    var onClose: (() -> Void)?
    private var isDismissing = false
    private let hasActions: Bool
    /// Only a modal confirm (actionable AND arming Return/Esc) should take first responder;
    /// a non-modal sticky toast must not, or it would steal input from the terminal.
    private let gatesFocus: Bool

    /// Fixed card width — toasts read as a consistent column rather than sizing to their text.
    private static let width: CGFloat = 300
    private static var titleColor: NSColor { Theme.current.chrome.foreground.nsColor }
    private static var messageColor: NSColor { Theme.current.chrome.muted.nsColor }

    convenience init(content: ToastContent) {
        self.init(content: content, actions: [])
    }

    init(content: ToastContent, actions: [ToastAction], keyEquivalents: Bool = true) {
        self.hasActions = !actions.isEmpty
        self.gatesFocus = keyEquivalents && !actions.isEmpty
        super.init(frame: .zero)
        let accent = content.variant.accent

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = content.variant.border.cgColor  // neutral for info; tinted for warning/destructive
        FloatShadow.applyShadow(to: self)

        // Tinted icon badge (accent glyph on an accent-at-15% rounded square).
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: content.icon ?? content.variant.defaultIcon,
            accessibilityDescription: content.title)
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        iconView.contentTintColor = accent
        iconView.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(iconView)

        // No close button — passive toasts dismiss on body-click / timeout; confirms answer
        // via their buttons (or Esc).
        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Self.titleColor

        let message = NSTextField(wrappingLabelWithString: content.message)
        message.font = .systemFont(ofSize: 12)
        message.textColor = Self.messageColor
        message.preferredMaxLayoutWidth = 236  // card width minus badge + gaps + insets

        let col = NSStackView(views: [title, message])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        message.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        if !actions.isEmpty {
            // Small buttons hugging the leading edge (a trailing spacer absorbs the slack).
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(
                views: actions.map { Self.button(for: $0, keyEquivalents: keyEquivalents) } + [spacer])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            col.addArrangedSubview(row)
            col.setCustomSpacing(9, after: message)
            row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }

        let root = NSStackView(views: [badge, col])
        root.orientation = .horizontal
        root.alignment = .top
        root.distribution = .fill  // stretch `col` to fill the fixed card width (badge stays 28)
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            iconView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Build a toast action button on the shared `AppButton`: `cancel` → a muted `secondary`,
    /// `destructive` → the destructive-tinted `destructive`. Return / Esc key equivalents mirror
    /// the action kind, unless `keyEquivalents` is off (a non-modal toast that must not hijack
    /// those keys window-wide).
    private static func button(for action: ToastAction, keyEquivalents: Bool) -> AppButton {
        let variant: AppButton.Variant = action.kind == .destructive ? .destructive : .secondary
        let keyEquivalent = keyEquivalents ? (action.kind == .destructive ? "\r" : "\u{1b}") : ""
        return AppButton(title: action.title, variant: variant, keyEquivalent: keyEquivalent, onTap: action.run)
    }

    /// A modal confirm takes keyboard focus so terminal input is gated while it's up; a
    /// non-modal sticky toast never does (its buttons are click-only).
    override var acceptsFirstResponder: Bool { gatesFocus }

    /// A body click dismisses a passive toast; a confirm ignores it (only "×"/buttons answer).
    override func mouseDown(with event: NSEvent) {
        if !hasActions { onClose?() }
    }

    /// A toast animating out ignores clicks, so a fast replace (a refreshed notification whose
    /// old card is still fading) can't have the outgoing card's Dismiss fire against the new one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDismissing ? nil : super.hitTest(point)
    }

    /// Spring the card in (fade + subtle scale about its center). Call after adding it.
    func animateIn() {
        superview?.layoutSubtreeIfNeeded()  // resolve the frame before scaling about its center
        Motion.springScaleFade(self, appearing: true)
    }

    /// Spring the card back out, then run `completion` (the presenter removes it).
    /// Idempotent — a second call (click + auto-dismiss racing) is ignored.
    func animateOut(completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        Motion.springScaleFade(self, appearing: false, completion: completion)
    }
}
