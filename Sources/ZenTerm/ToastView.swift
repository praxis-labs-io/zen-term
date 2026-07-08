import AppKit

/// One toast's content: an SF Symbol, a terse title, and a description line.
struct ToastContent: Equatable {
    let symbol: String
    let title: String
    let message: String
}

/// A transient notification card: an SF Symbol, a bold title, and a muted description,
/// on the same elevated dark card chrome as the float overlays (`FloatShadow`). Springs
/// in/out on the shared `Motion` system; a click dismisses it early. The `ToastPresenter`
/// owns placement (top-right) and lifetime.
final class ToastView: NSView {
    /// Called when the card is clicked — the presenter dismisses it early.
    var onClick: (() -> Void)?
    private var isDismissing = false
    private let hasActions: Bool

    // Same card chrome as the float overlays (bg + hairline edge); the drop shadow lifts it
    // off the terminal. Title reuses the theme foreground; the muted description tone isn't a
    // named Theme slot, so it stays a local Rosé Pine Moon "subtle" literal.
    private static let titleColor = Theme.rosePineMoon.foreground.nsColor
    private static let messageColor = NSColor(srgbRed: 0x90 / 255, green: 0x8c / 255, blue: 0xaa / 255, alpha: 1)

    convenience init(content: ToastContent, tint: NSColor) {
        self.init(content: content, tint: tint, actions: [])
    }

    /// Designated init. Passive toasts pass `actions: []`; a confirm toast passes its
    /// answer buttons, which render as a full-width row (equal widths, gapped) across
    /// the bottom of the card.
    init(content: ToastContent, tint: NSColor, actions: [ToastAction]) {
        self.hasActions = !actions.isEmpty
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.rosePineMoon.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.applyShadow(to: self)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: content.title)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Self.titleColor

        // Header row: icon + title on one line, description stacked below.
        let header = NSStackView(views: [icon, title])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let message = NSTextField(wrappingLabelWithString: content.message)
        message.font = .systemFont(ofSize: 12)
        message.textColor = Self.messageColor
        message.preferredMaxLayoutWidth = 240

        let col = NSStackView(views: [header, message])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)

        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            col.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])

        if !actions.isEmpty {
            let row = NSStackView(views: actions.map(ToastButton.init))
            row.orientation = .horizontal
            row.distribution = .fillEqually  // equal-width buttons across the card
            row.spacing = 8
            col.addArrangedSubview(row)
            col.setCustomSpacing(11, after: message)  // a touch more air above buttons
            row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true  // span full width
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A confirm toast takes keyboard focus so terminal input is gated while it's up.
    override var acceptsFirstResponder: Bool { hasActions }

    override func mouseDown(with event: NSEvent) { onClick?() }

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
