import AppKit
import TerminalKit

final class PanelHostView: NSView, TerminalModeHost, ThemeReapplying {
    private let onFocusRequest: () -> Void
    private let pane = NSView()
    private let clip = NSView()
    private let content: NSView
    private let ring = RingFillView()
    // A sibling above `clip`, not inside it: a mode strip mounts into `clip` later and would land above it.
    private let veil = PaneVeilView()
    let header: PaneHeader?
    // Content that isn't a terminal paints no background of its own, so a translucent panel fills it whole.
    private let fillsContent: Bool

    // Lazy only so its callback can capture self: `init` builds it, since it pins the content and mounts the header.
    private lazy var chrome = ModeChrome(
        container: clip, content: content, padding: padding, header: header,
        onStripsChanged: { [weak self] in self?.stripsMoved() })

    var isFocused: Bool = false { didSet { if oldValue != isFocused { updateBorder() } } }

    // Whether focus sits here, which the focus border shows only while panes share the screen.
    var isActive: Bool = false { didSet { header?.isActive = isActive } }

    var isZoomed: Bool = false { didSet { header?.isZoomed = isZoomed } }

    func setScrollCursor(
        _ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?
    ) {
        chrome.setScrollCursor(state, metrics: metrics)
    }

    @discardableResult
    func setFindFieldShown(_ shown: Bool) -> FindField? { chrome.setFindFieldShown(shown) }

    /// Background first: below alpha 1 that unhides the ring, and a hidden view drops a redisplay request.
    private func stripsMoved() {
        applyBackground()
        ring.needsDisplay = true
    }

    var scrollCursorForTesting: ScrollCursorView { chrome.scrollCursorForTesting }

    /// `cacheDisplay` draws regardless of `needsDisplay`, so a rendered check cannot stand in for this.
    var ringNeedsDisplayForTesting: Bool { ring.needsDisplay }

    private let padding: CGFloat = ChromeMetrics.Spacing.s10

    @MainActor static var cornerRadius: CGFloat {
        max(minCornerRadius, WindowCorner.radius - ChromeMetrics.windowGutter)
    }

    /// A pane far from the window corner still reads as a pane, so the concentric result has a floor.
    private static let minCornerRadius: CGFloat = ChromeMetrics.Radius.control

    init(
        content: NSView, header: PaneHeader? = nil, fillsContent: Bool = false,
        onFocusRequest: @escaping () -> Void
    ) {
        self.onFocusRequest = onFocusRequest
        self.fillsContent = fillsContent
        self.content = content
        self.header = header
        super.init(frame: .zero)

        wantsLayer = true
        pane.wantsLayer = true
        pane.layer?.cornerRadius = Self.cornerRadius
        pane.layer?.masksToBounds = false
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
        veil.translatesAutoresizingMaskIntoConstraints = false
        veil.cornerRadius = Self.cornerRadius
        pane.addSubview(veil)
        chrome.applyHeaderShown()
        applyBackground()

        pane.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: topAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            clip.topAnchor.constraint(equalTo: pane.topAnchor),
            clip.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            veil.topAnchor.constraint(equalTo: pane.topAnchor),
            veil.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            ring.topAnchor.constraint(equalTo: clip.topAnchor),
            ring.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -padding),
        ])

        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Only marks the ring dirty: AppKit lays out top-down, so `content` is not positioned yet here.
    override func layout() {
        super.layout()
        ring.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        veil.setRaised((window as? HostWindow)?.floatCoversPanes ?? false, animated: false)
    }

    func floatCoverDidChange(_ covered: Bool) { veil.setRaised(covered, animated: true) }

    var isVeiledForTesting: Bool { veil.isRaised }

    var backgroundOverride: TerminalColor? {
        didSet {
            guard oldValue != backgroundOverride else { return }
            applyBackground()
        }
    }

    var paintedBackgroundForTesting: (fill: CGColor?, ring: NSColor) {
        (clip.layer?.backgroundColor, ring.color)
    }

    var cornerRadiusForTesting: CGFloat { pane.layer?.cornerRadius ?? -1 }

    var borderForTesting: (color: CGColor?, width: CGFloat) {
        (pane.layer?.borderColor, pane.layer?.borderWidth ?? -1)
    }

    var shownHeaderForTesting: PaneHeader? { chrome.shownHeaderForTesting }

    var findFieldForTesting: FindField? { chrome.findFieldForTesting }

    var isHitTransparent = false
    override func hitTest(_ point: NSPoint) -> NSView? { isHitTransparent ? nil : super.hitTest(point) }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest()
        super.mouseDown(with: event)
    }

    private static var idleBorder: NSColor { Theme.current.chrome.fill(alpha: ChromeTheme.hairline) }

    func reapplyTheme() {
        applyBackground()
        updateBorder()
    }

    func reapplyTerminalBehavior() { applyBackground() }

    func reapplyChromeLayout() {
        let radius = Self.cornerRadius
        pane.layer?.cornerRadius = radius
        clip.layer?.cornerRadius = radius
        ring.cornerRadius = radius
        veil.cornerRadius = radius
        chrome.applyHeaderShown()
    }

    /// Translucent, the clip stops filling, or it repaints the terminal background behind a see-through surface.
    private func applyBackground() {
        let background = (backgroundOverride ?? Theme.current.chrome.background).nsColor
        let alpha = CGFloat(GeneralConfig.current.backgroundAlpha)
        let isSolid = GeneralConfig.current.terminalBehavior.isBackgroundSolid
        let translucent = background.withAlphaComponent(alpha)
        clip.layer?.backgroundColor = isSolid ? background.cgColor : (fillsContent ? translucent.cgColor : nil)
        ring.isHidden = isSolid || fillsContent
        ring.color = translucent
        veil.color = background
    }

    private func updateBorder() {
        pane.layer?.borderColor = (isFocused ? Theme.current.chrome.accent.nsColor : Self.idleBorder).cgColor
        pane.layer?.borderWidth = isFocused ? ChromeMetrics.Border.paneFocus : ChromeMetrics.Border.width
    }
}
