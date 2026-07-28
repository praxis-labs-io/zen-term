import AppKit
import TerminalKit

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
    private let ring = RingFillView()  // paints the inset once the card fill stops covering it
    private let elevation = OutsideShadowView()  // the elevation shadow, drawn around the card
    private let blur = NSVisualEffectView()  // frosts the panes behind a translucent card
    private var dismiss = DismissGate()

    /// The background a program set in this float's own terminal with OSC 11, or nil while the
    /// float is on the theme's (ZEN-23). Reaches the card's interior fill alone; the card edge,
    /// the elevation shadow and the frost stay as they are. Same rule a pane follows in
    /// `PanelHostView`, because a float hosts the same kind of surface.
    var backgroundOverride: TerminalColor? {
        didSet {
            guard oldValue != backgroundOverride else { return }
            applyBackground()
        }
    }

    /// Test hook: the colors actually painted into the card's interior (ZEN-23), read off the
    /// layer and the ring view rather than off `backgroundOverride`. `fill` is nil below
    /// `background-alpha` 1, where the ring paints instead.
    var paintedBackgroundForTesting: (fill: CGColor?, ring: NSColor) {
        (card.layer?.backgroundColor, ring.color)
    }

    /// How far the elevation shadow reaches past the card. Measured: at `shadowBlur` it dies out
    /// 38pt below the card's bottom edge, the `shadowOffset` included, and less on the other three
    /// sides. A view can't paint outside its own bounds, so anything short of that clips the
    /// shadow into a hard edge.
    private static let shadowOutset: CGFloat = 40

    /// `CGContext` blur matching the `CALayer.shadowRadius` of 14 this replaced. The two are not
    /// the same scale and the number can't be carried across, so it was measured rather than
    /// guessed: rendering both and sampling the alpha profile below the card's edge, blur 28 tracks
    /// radius 14 point for point (peak 0.392, dying by 38pt), where a literal 14 would land at
    /// roughly half the reach. Keep the pair together if either is ever retuned.
    private static let shadowBlur: CGFloat = 28
    private static let shadowOffset = NSSize(width: 0, height: -12)  // AppKit y-up: cast downward

    /// - Parameters:
    ///   - content: the view hosted in the card (e.g. a terminal surface's view).
    ///   - widthFraction / heightFraction: card size as a fraction of the tile. Relaxable
    ///     (`.defaultHigh`) with no fixed min/max, so the card tracks the window and never
    ///     drives the window (or terminal) to grow.
    ///   - contentInset: padding between the card edge and the content, so the content
    ///     stays off the rounded corners.
    ///   - cornerRadius: the card's corner radius.
    init(
        content: NSView,
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

        CardChrome.applyTerminalHost(to: card, cornerRadius: cornerRadius, halo: true)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Both the shadow and the ring live INSIDE the card, not beside it, so the spring on
        // present/dismiss carries them: `Motion.springScaleFade` animates the card's layer alone,
        // and a sublayer inherits its transform and opacity where a sibling would pop in flat.
        // The shadow reaches past the card's bounds, which is legal only while `masksToBounds`
        // stays off (`CardChrome.applyTerminalHost` keeps it off). The card's layer border draws above both.
        elevation.color = NSColor.black.withAlphaComponent(0.5)  // theme-independent, like FloatShadow's
        elevation.outset = Self.shadowOutset
        elevation.cornerRadius = cornerRadius
        elevation.blur = Self.shadowBlur
        elevation.offset = Self.shadowOffset
        elevation.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(elevation)

        // A translucent PANE reveals the window's `.behindWindow` blur, because the window itself
        // is transparent under it and the desktop is what's behind. A float has opaque panes
        // behind it instead, so the same alpha would show sharp terminal text through the card and
        // read as a hole rather than a surface. This is the equivalent frost, taken in-window: it
        // blurs whatever the card covers, so a see-through float reads like a see-through pane.
        // Rounded here rather than by the card, whose `masksToBounds` has to stay off for the
        // shadow.
        blur.material = .hudWindow  // the material `layoutContainer` gives the window backdrop
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(blur)  // above the shadow, below the ring

        ring.cornerRadius = cornerRadius
        ring.contentView = content
        ring.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(ring)  // above the blur, below the terminal

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
            elevation.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: -Self.shadowOutset),
            elevation.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: Self.shadowOutset),
            elevation.topAnchor.constraint(equalTo: card.topAnchor, constant: -Self.shadowOutset),
            elevation.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: Self.shadowOutset),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ring.topAnchor.constraint(equalTo: card.topAnchor),
            ring.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: contentInset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -contentInset),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: contentInset),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -contentInset),
        ])

        applyBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mark the ring for redisplay; it reads the terminal's frame itself, at draw time. Setting
    /// the hole from here instead would read a frame that is still stale: AppKit lays a tree out
    /// top-down, so `content` — a descendant, inside `card` — has not been positioned yet when
    /// this runs.
    override func layout() {
        super.layout()
        ring.needsDisplay = true
    }

    /// Who paints the card's interior, which `background-alpha` swaps between two arrangements —
    /// the same split `PanelHostView.applyBackground` makes for a pane, because a float hosts the
    /// same kind of surface.
    ///
    /// Solid (the default): the card fills edge to edge, so the inset ring and the area under the
    /// terminal are one flat colour, and the frost behind them stands down (it would be invisible
    /// under an opaque fill, and an `NSVisualEffectView` is not free).
    ///
    /// Translucent: the card has to stop filling, or it repaints the terminal background behind a
    /// surface that is now see-through and nothing shows through — worse here than for a pane,
    /// because the chrome background IS the colour the terminal blends toward, so the alpha
    /// cancels out exactly. The ring takes over the inset alone at the same alpha the terminal
    /// blends at, so the two read as one surface instead of the ring sitting a shade lighter. The
    /// frost comes up underneath both, so what shows through is a blur of the panes rather than
    /// their text. Both values are re-read here rather than captured at init, so a Settings edit
    /// applies live.
    private func applyBackground() {
        let background = (backgroundOverride ?? Theme.current.chrome.background).nsColor
        let alpha = CGFloat(GeneralConfig.current.backgroundAlpha)
        let isSolid = GeneralConfig.current.terminalBehavior.isBackgroundSolid
        card.layer?.backgroundColor = isSolid ? background.cgColor : nil
        ring.isHidden = isSolid
        blur.isHidden = isSolid
        ring.color = background.withAlphaComponent(alpha)
    }

    /// Re-apply the card's theme-dependent colors after a live theme change, and re-read
    /// `background-alpha` — so this has to be reached by a terminal-behavior change too, not only
    /// a theme swap. The elevation shadow is theme-independent and untouched.
    func reapplyTheme() {
        CardChrome.reapplyEdge(to: card, halo: true)
        applyBackground()
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
