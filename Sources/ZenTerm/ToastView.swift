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

/// A transient notification card: a tinted icon badge, a title (with a close affordance when the
/// card has buttons), a muted description, and an optional small actions row — on the shared
/// overlay-card chrome
/// (`FloatShadow` bg + hairline edge + drop shadow). Fixed width; springs in/out on `Motion`.
/// The `ToastPresenter` owns placement (top-right) and lifetime.
final class ToastView: ShadowCardView {
    /// The "×" (and, for a passive toast, a body click) fires this — the presenter dismisses,
    /// or a confirm cancels.
    var onClose: (() -> Void)?
    private var isDismissing = false
    private let hasActions: Bool
    /// Only a modal confirm (actionable AND arming Return/Esc) should take first responder;
    /// a non-modal sticky toast must not, or it would steal input from the terminal.
    private let gatesFocus: Bool
    /// The border tone (neutral for info, tinted for warning/destructive) — re-derived in
    /// `reapplyTheme()` since it's a `Theme.current.chrome`-sourced value baked at init.
    private let variant: ToastVariant
    /// Retained (not throwaway init-locals) so `reapplyTheme()` can recolor them — otherwise an
    /// already-visible toast (e.g. a confirm left up across ⌘⇧,) stays stale after a live theme
    /// change, since a passive `show()` toast is never rebuilt while an old one lingers.
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    /// Retained so `reapplyTheme()` can recolor it, like every other baked-color control here.
    private var closeButton: IconButton?

    /// Fixed card width — toasts read as a consistent column rather than sizing to their text.
    private static let width: CGFloat = 300

    /// The message column's wrap width (card width minus badge + gaps + insets) and its font.
    /// Exposed so copy can be *measured* against the real budget instead of eyeballed: a line that
    /// reads fine in a commit message wraps mid-phrase at 236pt, and asserting the string tells you
    /// nothing about that.
    static let messageMaxWidth: CGFloat = 236
    static let messageFont: NSFont = .systemFont(ofSize: 12)
    private static var titleColor: NSColor { Theme.current.chrome.foreground.nsColor }
    private static var messageColor: NSColor { Theme.current.chrome.muted.nsColor }

    convenience init(content: ToastContent) {
        self.init(content: content, actions: [])
    }

    /// The action keycaps, retained so a live toast can re-resolve them (a tab closing under it) and
    /// recolor them on a theme swap.
    private var shortcutSlots: [ShortcutSlot] = []

    init(
        content: ToastContent, actions: [ToastAction], keyEquivalents: Bool = true,
        showsClose: Bool = false
    ) {
        self.hasActions = !actions.isEmpty
        self.gatesFocus = keyEquivalents && !actions.isEmpty
        self.variant = content.variant
        self.titleLabel = NSTextField(labelWithString: content.title)
        self.messageLabel = NSTextField(wrappingLabelWithString: content.message)
        super.init(frame: .zero)
        let accent = content.variant.accent

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
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

        // A card with buttons gets a close affordance; a passive one dismisses on body-click or
        // its timer and needs none. Without it an actionable card could only be answered, and a
        // conflict card has to be dismissible without writing to the config.
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Self.titleColor
        // The title shares its row with the keycap now, and it's a tab title — arbitrary length.
        // Truncate it rather than let it push the keycap off the card's edge.
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        messageLabel.font = Self.messageFont
        messageLabel.textColor = Self.messageColor
        messageLabel.preferredMaxLayoutWidth = Self.messageMaxWidth

        // Title leading, keycaps trailing, with a spacer holding them apart. The keycap names an
        // app-level binding rather than labelling a button (the toast arms nothing), so
        // the card's top-right corner reads as "this toast's chord" instead of implying the button
        // beside it has a key equivalent.
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, headerSpacer])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let col = NSStackView(views: [header, messageLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        messageLabel.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        header.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        // Appended after the spacer, so a keycap lands on the trailing edge.
        for resolve in actions.compactMap(\.shortcut) {
            let slot = ShortcutSlot(group: header, resolve: resolve)
            shortcutSlots.append(slot)
            slot.refresh()
        }

        // Last, so the × takes the trailing corner even on a card that also carries a keycap.
        //
        // Opt-in rather than "any card with buttons": the button does nothing unless its host wires
        // `onClose`, and only the conflict card does. On by default it drew a dead × on the config
        // notice, both attention toasts, the terminal-failure toast and every confirm, and a confirm
        // gates keyboard focus, so clicking it left the card up and the terminal deaf.
        if showsClose {
            let close = IconButton(
                symbol: "xmark", size: NSSize(width: 20, height: 20), pointSize: 10,
                accessibilityLabel: "Dismiss"
            ) { [weak self] in self?.onClose?() }
            header.addArrangedSubview(close)
            closeButton = close
        }

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
            col.setCustomSpacing(9, after: messageLabel)
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
    /// `destructive` → the destructive-tinted `destructive`, `primary` → the accent `primary`. The
    /// affirmative kinds (primary/destructive) take Return and `cancel` takes Esc, unless
    /// `keyEquivalents` is off (a non-modal toast that must not hijack those keys window-wide).
    private static func button(for action: ToastAction, keyEquivalents: Bool) -> AppButton {
        let variant: AppButton.Variant
        switch action.kind {
        case .primary: variant = .primary
        case .destructive: variant = .destructive
        case .cancel: variant = .secondary
        }
        let keyEquivalent = keyEquivalents ? (action.kind == .cancel ? "\u{1b}" : "\r") : ""
        return AppButton(title: action.title, variant: variant, keyEquivalent: keyEquivalent, onTap: action.run)
    }

    /// One action's keycap slot: the row it lives in and the query for its current glyph. The glyph
    /// isn't baked — a toast for tab 3 must stop reading "⌘3" once a tab before it closes — and
    /// `KeycapView` bakes its own at construction, so refreshing rebuilds the keycap.
    private final class ShortcutSlot {
        private let group: NSStackView
        private let resolve: () -> String
        private var keycap: KeycapView?

        init(group: NSStackView, resolve: @escaping () -> String) {
            self.group = group
            self.resolve = resolve
        }

        /// Re-resolve the glyph and rebuild the keycap when it changed. A no-op when it didn't, so
        /// the common re-render (a tab switch that moves nothing) doesn't churn views.
        func refresh() {
            let glyph = resolve()
            guard glyph != keycap?.shortcut else { return }
            keycap.map { group.removeArrangedSubview($0) }
            keycap?.removeFromSuperview()
            keycap = nil
            guard !glyph.isEmpty else { return }  // unbound (a tab past ⌘9) → no keycap at all
            let cap = KeycapView(shortcut: glyph)
            group.addArrangedSubview(cap)
            keycap = cap
        }

        func reapplyTheme() { keycap?.reapplyTheme() }
    }

    /// A modal confirm takes keyboard focus so terminal input is gated while it's up; a
    /// non-modal sticky toast never does (its buttons are click-only).
    override var acceptsFirstResponder: Bool { gatesFocus }

    /// A body click dismisses a passive toast; an actionable one ignores it, so a misclick can't
    /// answer a question. Its "×" and its buttons are the only ways out.
    override func mouseDown(with event: NSEvent) {
        if !hasActions { onClose?() }
    }

    /// A toast animating out ignores clicks, so a fast replace (a refreshed notification whose
    /// old card is still fading) can't have the outgoing card's Dismiss fire against the new one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDismissing ? nil : super.hitTest(point)
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. Needed for a toast
    /// left up across the change (e.g. a `.reloadConfig` confirm, which has no modal gate): a
    /// passive `show()` toast is only ever built fresh, so an already-visible one would
    /// otherwise stay stale until it's dismissed and replaced.
    func reapplyTheme() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderColor = FloatShadow.edge.cgColor
        titleLabel.textColor = Self.titleColor
        messageLabel.textColor = Self.messageColor
        shortcutSlots.forEach { $0.reapplyTheme() }  // else the keycap ink goes stale on a theme swap
        closeButton?.reapplyTheme()
    }

    /// Re-resolve every action keycap against the live keymap and tab order. The host calls this
    /// whenever tabs mutate: a toast is built once per notification, so one for tab 3 would keep
    /// reading "⌘3" after tab 1 closes and point at the wrong tab.
    func refreshShortcuts() {
        shortcutSlots.forEach { $0.refresh() }
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
