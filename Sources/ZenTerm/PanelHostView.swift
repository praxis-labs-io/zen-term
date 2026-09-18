import AppKit
import TerminalKit

struct PanelMeta {
    let title: String
    let action: KeyInterceptor.ReservedChord
}

final class PanelHostView: NSView, TerminalModeHost {
    private let onFocusRequest: () -> Void
    private let pane = NSView()
    private let clip = NSView()
    private let content: NSView
    private let ring = RingFillView()
    private let halo = OutsideShadowView()
    private let baseMeta: PanelMeta?
    private let zoomMeta: PanelMeta?

    private lazy var chrome = ModeChrome(
        container: clip, content: content, padding: padding, header: baseMeta ?? zoomMeta,
        onStripsChanged: { [weak self] in self?.stripsMoved() })

    var isFocused: Bool = false { didSet { if oldValue != isFocused { updateHalo() } } }

    var isZoomed: Bool = false {
        didSet {
            guard oldValue != isZoomed else { return }
            updateHeader()
        }
    }

    var modeMeta: PanelMeta? {
        didSet {
            guard oldValue?.title != modeMeta?.title || oldValue?.action != modeMeta?.action else { return }
            updateHeader()
        }
    }

    func setScrollCursor(
        _ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?
    ) {
        chrome.setScrollCursor(state, metrics: metrics)
    }

    @discardableResult
    func setFindBarShown(_ shown: Bool) -> FindBarView? { chrome.setFindBarShown(shown) }

    /// Background first: below alpha 1 that unhides the ring, and a hidden view drops a redisplay request.
    private func stripsMoved() {
        applyBackground()
        ring.needsDisplay = true
    }

    var scrollCursorForTesting: ScrollCursorView { chrome.scrollCursorForTesting }

    /// `cacheDisplay` draws regardless of `needsDisplay`, so a rendered check cannot stand in for this.
    var ringNeedsDisplayForTesting: Bool { ring.needsDisplay }

    private let padding: CGFloat = 10

    /// Concentric with the window only when nothing sits between them: window chrome puts the top corners 28pt clear of it.
    @MainActor static var cornerRadius: CGFloat {
        guard !GeneralConfig.current.windowChrome else { return chromeCornerRadius }
        return max(minCornerRadius, WindowCorner.radius - ChromeMetrics.windowGutter)
    }

    private static let chromeCornerRadius: CGFloat = 12

    /// A pane far from the window corner still reads as a pane, so the concentric result has a floor.
    private static let minCornerRadius: CGFloat = 6

    /// An `NSView` cannot paint outside its bounds, and the glow has to.
    private static let haloOutset: CGFloat = 16

    /// A CGContext shadow renders far weaker than a CALayer one.
    private static let haloOpacity: Float = 0.45

    private static let haloBlur: CGFloat = 8

    init(
        content: NSView, meta: PanelMeta?, zoomMeta: PanelMeta? = nil,
        onFocusRequest: @escaping () -> Void
    ) {
        self.onFocusRequest = onFocusRequest
        self.content = content
        self.baseMeta = meta
        self.zoomMeta = zoomMeta
        super.init(frame: .zero)

        wantsLayer = true
        pane.wantsLayer = true
        pane.layer?.cornerRadius = Self.cornerRadius
        pane.layer?.masksToBounds = false
        pane.layer?.borderWidth = 1
        halo.wantsLayer = true
        halo.layer?.opacity = 0
        halo.color = Theme.current.chrome.accent.nsColor
        halo.outset = Self.haloOutset
        halo.cornerRadius = Self.cornerRadius
        halo.blur = Self.haloBlur
        halo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(halo)
        addSubview(pane)

        content.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(clip)
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.cornerRadius = Self.cornerRadius
        ring.contentView = content
        clip.addSubview(ring)
        clip.addSubview(content)
        applyBackground()

        pane.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: topAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            halo.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: -Self.haloOutset),
            halo.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: Self.haloOutset),
            halo.topAnchor.constraint(equalTo: pane.topAnchor, constant: -Self.haloOutset),
            halo.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: Self.haloOutset),
            clip.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            clip.topAnchor.constraint(equalTo: pane.topAnchor),
            clip.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            ring.topAnchor.constraint(equalTo: clip.topAnchor),
            ring.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -padding),
        ])

        updateHeader()
        updateHalo()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Only marks the ring dirty: AppKit lays out top-down, so `content` is not positioned yet here.
    override func layout() {
        super.layout()
        ring.needsDisplay = true
    }

    var backgroundOverride: TerminalColor? {
        didSet {
            guard oldValue != backgroundOverride else { return }
            applyBackground()
        }
    }

    var haloOpacityForTesting: Float { halo.layer?.opacity ?? -1 }

    var paintedBackgroundForTesting: (fill: CGColor?, ring: NSColor) {
        (clip.layer?.backgroundColor, ring.color)
    }

    var cornerRadiusForTesting: CGFloat { pane.layer?.cornerRadius ?? -1 }

    var haloGeometryForTesting: (frame: NSRect, isBelowCard: Bool) {
        let haloIndex = subviews.firstIndex(of: halo)
        let paneIndex = subviews.firstIndex(of: pane)
        guard let haloIndex, let paneIndex else { return (halo.frame, false) }
        return (halo.frame, haloIndex < paneIndex)
    }

    var isHeaderVisibleForTesting: Bool { chrome.isHeaderVisibleForTesting }

    var headerContentForTesting: (title: String, shortcut: String)? { chrome.headerContentForTesting }

    var builtHeaderKeycapForTesting: String? { chrome.builtHeaderKeycapForTesting }

    var findBarForTesting: FindBarView? { chrome.findBarForTesting }

    var isHitTransparent = false
    override func hitTest(_ point: NSPoint) -> NSView? { isHitTransparent ? nil : super.hitTest(point) }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest()
        super.mouseDown(with: event)
    }

    private func updateHeader() {
        chrome.setHeader(modeMeta ?? (isZoomed ? zoomMeta : nil) ?? baseMeta)
    }

    private static var idleBorder: NSColor { Theme.current.chrome.fill(alpha: ChromeTheme.hairline) }

    func reapplyTheme() {
        halo.color = Theme.current.chrome.accent.nsColor
        applyBackground()
        chrome.reapplyTheme()
        updateHalo()
    }

    func reapplyChromeLayout() {
        let radius = Self.cornerRadius
        pane.layer?.cornerRadius = radius
        clip.layer?.cornerRadius = radius
        halo.cornerRadius = radius
        ring.cornerRadius = radius
    }

    /// Translucent, the clip stops filling, or it repaints the terminal background behind a see-through surface.
    private func applyBackground() {
        let background = (backgroundOverride ?? Theme.current.chrome.background).nsColor
        let alpha = CGFloat(GeneralConfig.current.backgroundAlpha)
        let isSolid = GeneralConfig.current.terminalBehavior.isBackgroundSolid
        clip.layer?.backgroundColor = isSolid ? background.cgColor : nil
        ring.isHidden = isSolid
        ring.color = background.withAlphaComponent(alpha)
        chrome.findBarFill = isSolid ? background : ring.color
    }

    private func updateHalo() {
        guard let layer = pane.layer, let haloLayer = halo.layer else { return }
        Motion.ease(
            layer, keyPath: "borderColor",
            to: (isFocused ? Theme.current.chrome.accent.nsColor : Self.idleBorder).cgColor)
        Motion.ease(haloLayer, keyPath: "opacity", to: isFocused ? Self.haloOpacity : 0)
    }
}
