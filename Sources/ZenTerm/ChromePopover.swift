import AppKit

/// A small themed popover primitive (ZEN-262): it wraps caller-supplied content in a rounded,
/// hairline-bordered card with a soft shadow, and shows or hides it anchored just above the trailing
/// edge of a reference view. The caller owns the trigger and the content; the popover owns the chrome,
/// the fade, and re-theming — so the same primitive backs any "press a key, get a floating panel" surface.
///
/// This is deliberately NOT the modal-card chrome (`CardChrome`): a reference popover is transient and
/// non-modal, so it casts a lighter shadow than a float, never dims, and never blocks the content behind
/// it. Content is supplied as a factory rather than a view, so a live theme change can rebuild it (its
/// keycaps and labels bake their colors in at construction) alongside the popover's own fill and border.
final class ChromePopover: NSView {
    private let makeContent: () -> NSView
    private var content: NSView?
    private var backdrop: BackdropView?

    init(makeContent: @escaping () -> NSView) {
        self.makeContent = makeContent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        applyShadow()
        applyThemeColors()
        installContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isShown: Bool { superview != nil }

    func toggle(in host: NSView, above anchor: NSView) {
        isShown ? hide() : show(in: host, above: anchor)
    }

    /// Show anchored so the popover's bottom-right sits just above `anchor`'s top-right, clamped to stay
    /// inside `host`. `host` must be an ancestor of `anchor` for the anchor constraints to resolve.
    func show(in host: NSView, above anchor: NSView, trailingInset: CGFloat = 12, gap: CGFloat = 8) {
        guard superview == nil else { return }
        // A transparent backdrop dismisses on any click outside the popover — the modal-style blur behavior.
        // The popover swallows its own clicks (see `mouseDown`), so only outside hits reach the backdrop.
        let backdrop = BackdropView { [weak self] in self?.hide() }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        self.backdrop = backdrop

        layer?.opacity = 0
        host.addSubview(self)  // above the backdrop, so it stacks over the content and the backdrop
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: anchor.trailingAnchor, constant: -trailingInset),
            bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -gap),
            leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 12),
            topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: 12),
        ])
        Motion.fade(self, to: 1)
    }

    func hide() {
        // Instant close (the fade is on the way in), so `isShown` stays synchronous.
        backdrop?.removeFromSuperview()
        backdrop = nil
        removeFromSuperview()
    }

    /// Swallow clicks landing on the popover so they don't reach the dismissing backdrop beneath it.
    override func mouseDown(with event: NSEvent) {}

    /// Re-derive the theme-dependent chrome and rebuild the content against `Theme.current` after a live
    /// theme swap (the content's keycaps bake their ink in at construction, so it's re-created).
    func reapplyTheme() {
        applyThemeColors()
        installContent()
    }

    private func installContent() {
        content?.removeFromSuperview()
        let view = makeContent()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        content = view
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func applyThemeColors() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
    }

    private func applyShadow() {
        // Set via `NSView.shadow`, never `layer.shadow*` — a nested subtree insertion re-syncs the view's
        // shadow over its backing layer and would zero a layer-written one (same reason as `FloatShadow`).
        layer?.masksToBounds = false
        let shadow = NSShadow()
        // Theme-independent black elevation like `FloatShadow`, but lighter: a reference popover, not a modal.
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -4)  // AppKit y-up: cast downward
        self.shadow = shadow
    }
}
