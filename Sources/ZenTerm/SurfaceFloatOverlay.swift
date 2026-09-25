import AppKit
import TerminalKit

class SurfaceFloatOverlay: NSView, TerminalModeHost {
    private let onDismiss: () -> Void
    private let content: NSView
    private let contentInset: CGFloat
    /// Not `CardView`, so the hosted terminal receives `mouseDown`.
    private let card = ShadowCardView()
    private let ring = RingFillView()
    /// Drawn in theme-independent black, like `FloatShadow`.
    private let elevation = OutsideShadowView()
    private let blur = NSVisualEffectView()
    private var dismiss = DismissGate()

    private lazy var chrome = ModeChrome(
        container: card, content: content, padding: contentInset, header: nil,
        onStripsChanged: { [weak self] in self?.stripsMoved() })

    var backgroundOverride: TerminalColor? {
        didSet {
            guard oldValue != backgroundOverride else { return }
            applyBackground()
        }
    }

    var paintedBackgroundForTesting: (fill: CGColor?, ring: NSColor) {
        (card.layer?.backgroundColor, ring.color)
    }

    /// Measured: at `shadowBlur` the shadow dies out 38pt below the card.
    private static let shadowOutset: CGFloat = 40

    /// Measured to match `CALayer.shadowRadius` 14; the `CGContext` blur is not the same scale.
    private static let shadowBlur: CGFloat = 28
    private static let shadowOffset = NSSize(width: 0, height: -12)

    init(
        content: NSView,
        widthFraction: CGFloat,
        heightFraction: CGFloat,
        contentInset: CGFloat,
        cornerRadius: CGFloat,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.content = content
        self.contentInset = contentInset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.wantsLayer = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.applyTerminalHost(to: card, cornerRadius: cornerRadius, halo: true)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        elevation.color = NSColor.black.withAlphaComponent(0.5)
        elevation.outset = Self.shadowOutset
        elevation.cornerRadius = cornerRadius
        elevation.blur = Self.shadowBlur
        elevation.offset = Self.shadowOffset
        elevation.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(elevation)

        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(blur)

        ring.cornerRadius = cornerRadius
        ring.contentView = content
        ring.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(ring)

        content.translatesAutoresizingMaskIntoConstraints = false
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
        ])

        applyBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Marks the ring for redisplay: `content` is not yet positioned while its ancestor lays out.
    override func layout() {
        super.layout()
        ring.needsDisplay = true
    }

    private func applyBackground() {
        let background = (backgroundOverride ?? Theme.current.chrome.background).nsColor
        let alpha = CGFloat(GeneralConfig.current.backgroundAlpha)
        let isSolid = GeneralConfig.current.terminalBehavior.isBackgroundSolid
        card.layer?.backgroundColor = isSolid ? background.cgColor : nil
        ring.isHidden = isSolid
        blur.isHidden = isSolid
        ring.color = background.withAlphaComponent(alpha)
        chrome.findBarFill = isSolid ? background : ring.color
    }

    var isHaloVisible = true {
        didSet { if oldValue != isHaloVisible { CardChrome.reapplyEdge(to: card, halo: isHaloVisible) } }
    }

    func reapplyTheme() {
        CardChrome.reapplyEdge(to: card, halo: isHaloVisible)
        applyBackground()
        chrome.reapplyTheme()
    }

    var modeMeta: PanelMeta? {
        didSet {
            guard oldValue?.title != modeMeta?.title || oldValue?.action != modeMeta?.action else { return }
            chrome.setHeader(modeMeta)
        }
    }

    func setScrollCursor(
        _ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?
    ) {
        chrome.setScrollCursor(state, metrics: metrics)
    }

    @discardableResult
    func setFindBarShown(_ shown: Bool) -> FindBarView? { chrome.setFindBarShown(shown) }

    private func stripsMoved() {
        applyBackground()
        ring.needsDisplay = true
    }

    var findBarForTesting: FindBarView? { chrome.findBarForTesting }
    var scrollCursorForTesting: ScrollCursorView { chrome.scrollCursorForTesting }
    var isHeaderVisibleForTesting: Bool { chrome.isHeaderVisibleForTesting }
    var headerContentForTesting: (title: String, shortcut: String)? { chrome.headerContentForTesting }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

}
