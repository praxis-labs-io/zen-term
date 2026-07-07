import AppKit

/// A modal overlay over the tab's tile region hosting the lazygit surface. It fills
/// exactly the tile area (its host pins it to `content`, so it never bleeds over the
/// window gutters or the tab bar): a dim backdrop over the panes behind, rounded to the
/// panel corner radius, and a centered card holding the surface. A click on the backdrop
/// dismisses; clicks inside the card reach lazygit.
final class LazygitOverlay: NSView {
    private let onDismiss: () -> Void

    private static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)

    init(content: NSView, background: NSColor, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Rounded to the panel corner radius so the frosted backdrop sits cleanly inside
        // the tile area rather than squaring off over the rounded panels beneath.
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // Dim backdrop over the panes behind; this view also catches backdrop clicks.
        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Self.iris.cgColor            // iris focus ring
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

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
