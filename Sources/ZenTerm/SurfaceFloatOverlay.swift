import AppKit

/// A float over a tab's tile region that centers a hosted content view inside a rounded
/// card, lifted off the panes by a dark elevation shadow, over a transparent click-catcher
/// that dismisses on an outside click. The card springs in on present and back out on
/// dismiss; clicks on the content reach it, clicks in the card's inset ring are inert.
///
/// Its host pins it to `content` (the tile region), so it never bleeds over the window
/// gutters or the tab bar. Hosts (the tool floats)
/// supply the content view and the card metrics — the base owns all the float chrome and
/// the enter/exit motion.
class SurfaceFloatOverlay: NSView {
    private let onDismiss: () -> Void
    // ShadowCardView (not CardView) — the hosted terminal must receive mouseDown.
    private let card = ShadowCardView()
    private var dismiss = DismissGate()

    /// - Parameters:
    ///   - content: the view hosted in the card (e.g. a terminal surface's view).
    ///   - background: the card fill.
    ///   - widthFraction / heightFraction: card size as a fraction of the tile. Relaxable
    ///     (`.defaultHigh`) with no fixed min/max, so the card tracks the window and never
    ///     drives the window (or terminal) to grow.
    ///   - contentInset: padding between the card edge and the content, so the content
    ///     stays off the rounded corners.
    ///   - cornerRadius: the card's corner radius.
    init(
        content: NSView,
        background: NSColor,
        widthFraction: CGFloat,
        heightFraction: CGFloat,
        contentInset: CGFloat,
        cornerRadius: CGFloat,
        onDismiss: @escaping () -> Void
    ) {
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

        CardChrome.apply(to: card, background: background, cornerRadius: cornerRadius, halo: true)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        content.translatesAutoresizingMaskIntoConstraints = false
        // The card is sized as a fraction of the tile (relaxable). A hosted terminal
        // surface defaults to a high compression resistance that would fight that fraction
        // and leak the terminal's intrinsic size into the layout. Drop its size influence
        // so the card fraction fully dictates the size and the terminal reflows to fill it
        // — exactly how a pane's container dictates its terminal.
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        card.addSubview(content)

        let w = card.widthAnchor.constraint(equalTo: widthAnchor, multiplier: widthFraction)
        w.priority = .defaultHigh
        let h = card.heightAnchor.constraint(equalTo: heightAnchor, multiplier: heightFraction)
        h.priority = .defaultHigh
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            w, h,
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: contentInset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -contentInset),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: contentInset),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -contentInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-apply the card's theme-dependent colors after a live theme change. The shadow
    /// (`FloatShadow.applyShadow`) is theme-independent and untouched.
    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card, halo: true)
    }

    /// Spring the card in (fade + subtle scale about its center). Call after presenting.
    func animateIn() {
        superview?.layoutSubtreeIfNeeded()  // resolve the card's frame before scaling about its center
        Motion.springScaleFade(card, appearing: true)
    }

    /// Spring the card back out, then run `completion` (the host removes the overlay and
    /// tears down the surface). Idempotent — a second call while dismissing is ignored.
    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    /// Once dismissal starts, stop intercepting clicks so a tap during the exit animation
    /// falls through to the panes instead of the still-present backdrop.
    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

}
