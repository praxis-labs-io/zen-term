import AppKit

/// A float over the tab's tile region hosting the lazygit surface. It fills exactly the
/// tile area (its host pins it to `content`, so it never bleeds over the window gutters or
/// the tab bar): a transparent click-catcher and a centered card holding the surface,
/// lifted off the panes by a dark elevation shadow. A click outside the card dismisses;
/// clicks on the terminal reach lazygit (clicks in the card's thin padding ring are inert
/// — they neither dismiss nor reach the terminal).
final class LazygitOverlay: NSView {
    private let onDismiss: () -> Void

    init(content: NSView, background: NSColor, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Transparent click-catcher over the panes behind (no dimming) — still dismisses
        // on an outside click.
        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.wantsLayer = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor  // subtle neutral edge
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        // Dark elevation shadow on the card itself (masksToBounds stays off so it isn't
        // clipped); the 10pt content inset keeps the terminal off the rounded corners.
        FloatShadow.applyShadow(to: card)

        content.translatesAutoresizingMaskIntoConstraints = false
        // The card is sized as a fraction of the tile (relaxable, `.defaultHigh`).
        // SwiftTerm's view defaults to a high compression resistance that would fight
        // that fraction and leak the terminal's intrinsic size into the layout. Drop its
        // size influence so the card fraction fully dictates the size and the terminal
        // reflows to fill it — exactly how a pane's container dictates its terminal.
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        card.addSubview(content)

        // Size purely as a fraction of the tile — no fixed minimum or maximum — so the
        // card always tracks the window and never drives the window (or terminal) to
        // grow; a required cap here was what shrank the OS window on open.
        let w = card.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.85)
        w.priority = .defaultHigh
        let h = card.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.78)
        h.priority = .defaultHigh
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            w, h,
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The dim tint layer; a click anywhere on it (i.e. outside the card) dismisses the
    /// float. Clicks on the card/terminal land on those subviews and never reach here.
    private final class BackdropView: NSView {
        private let onClick: () -> Void
        init(onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
