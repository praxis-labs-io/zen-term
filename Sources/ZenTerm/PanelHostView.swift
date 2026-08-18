import AppKit
import TerminalKit

/// A panel's top header: a muted small-caps title (left) and its live keybind (right),
/// e.g. `("Bottom drawer", .toggleBottomDrawer)` → `BOTTOM DRAWER  ⌘B`. Replaces the old
/// floating corner icons: a labeled header, not a control; the toggle lives in the footer
/// dock and the keymap.
struct PanelMeta {
    let title: String
    let action: KeyInterceptor.ReservedChord
}

/// Hosts one terminal surface (a pane leaf or a drawer) inside the shared rounded/bordered
/// chrome: the iris focus halo (accent border + soft glow) and an inner clip that keeps
/// content within the corner radius. A drawer passes `meta` for an always-on header, and may
/// also pass `zoomMeta`: the header content it swaps to while zoomed (its title reading
/// "<panel>: Focus Mode" and the keybind replaced by ⌘⇧⏎). A pane passes only `zoomMeta` for a
/// header that appears only while the pane is zoomed (Focus Mode). Panes with neither
/// look/behave exactly as the original pane-only chrome. Clicking anywhere in the panel
/// requests focus.
final class PanelHostView: NSView, TerminalModeHost {
    private let onFocusRequest: () -> Void
    private let pane = NSView()  // the bordered card; the glow is cast by `halo`, not by a shadow
    private let clip = NSView()  // inner clip so terminal content stays inside the radius
    private let content: NSView  // the terminal surface's own view
    private let ring = RingFillView()  // paints the padding ring once the clip stops filling it
    private let halo = OutsideShadowView()  // the focus glow, cast around the card from beneath it
    /// The header content for the resting vs zoomed state. A pane has only `zoomMeta` (header hidden
    /// until zoomed); a drawer has both (its base header ⇄ the zoom variant). `updateHeader` picks
    /// the meta for the current state, `modeMeta ?? (isZoomed ? zoomMeta : nil) ?? baseMeta`, where a
    /// nil result hides the header. One rule covers all three cases.
    private let baseMeta: PanelMeta?
    private let zoomMeta: PanelMeta?

    /// The mode strips: the header, the find bar and scroll mode's cursor. Lazy because it mounts
    /// into `clip` around `content`, so it cannot be built before `self` is.
    private lazy var chrome = ModeChrome(
        container: clip, content: content, padding: padding, header: baseMeta ?? zoomMeta,
        onStripsChanged: { [weak self] in self?.stripsMoved() })

    var isFocused: Bool = false { didSet { if oldValue != isFocused { updateHalo() } } }

    /// Whether this panel is the sole full-canvas panel (zoomed). A pane reveals its
    /// Focus Mode header; a drawer keeps its always-on header but swaps its content to the
    /// zoomed variant (title + ⌘F).
    var isZoomed: Bool = false {
        didSet {
            guard oldValue != isZoomed else { return }
            updateHeader()
        }
    }

    /// A transient header this panel is wearing for as long as a mode is up over it (scroll
    /// mode), outranking both the zoom and base metas. Set to nil to give the header
    /// back to whichever of those the panel's state calls for.
    ///
    /// It carries live text, so it is assigned on every scroll report, which is why
    /// `PanelHeader.apply` rebuilds the keycap only when the action actually moves.
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

    /// A strip moved the terminal, so the hole the ring punches for it moved too. Re-read the
    /// background first: below alpha 1 that is what unhides the ring, and a hidden view drops a
    /// redisplay request rather than holding it until it is shown.
    private func stripsMoved() {
        applyBackground()
        ring.needsDisplay = true
    }

    var scrollCursorForTesting: ScrollCursorView { chrome.scrollCursorForTesting }

    /// Test hook: whether the padding ring is queued to repaint. Toggling a strip resizes the terminal,
    /// which moves the hole the ring punches out of the padding, and nothing else in the panel marks it.
    /// A rendered check can't stand in for this: `cacheDisplay` draws regardless of the flag,
    /// so it paints the band correctly even when the app would not.
    var ringNeedsDisplayForTesting: Bool { ring.needsDisplay }

    /// Inner breathing room between the pane border and the terminal content, even on
    /// all sides so content (e.g. nvim) doesn't sit against the pane border.
    private let padding: CGFloat = 10

    /// The panel's rounded corner. Three layers have to agree on it — the bordered card, the
    /// clip that keeps content inside it, and the ring that fills the padding — so they read it
    /// from here rather than each carrying its own copy to drift out of step.
    static let cornerRadius: CGFloat = 12

    /// How far the focus glow reaches past the panel's edge. The halo view is outset by this much
    /// because an `NSView` can't paint outside its own bounds, and the glow has to.
    private static let haloOutset: CGFloat = 16

    /// The focus glow's strength, as the halo view's own opacity. Not the 0.3 the card's
    /// `shadowOpacity` used: a CGContext shadow renders far weaker than a CALayer one, so most of
    /// the dimming is already in the draw and 0.3 on top of it made the glow vanish.
    private static let haloOpacity: Float = 0.45

    /// The glow's blur, in `CGContext` terms. 8 sits between the two measured points in
    /// `OutsideShadowView.blur` — far enough to read as a glow without the purple wash the wider
    /// end spreads around a pane.
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
        pane.layer?.masksToBounds = false  // content is clipped by `clip` below, not by the card
        pane.layer?.borderWidth = 1
        // The focus glow is its own view beneath the card, not a shadow on the card — see
        // OutsideShadowView. Its color is fixed; only its opacity toggles (animated in updateHalo).
        halo.wantsLayer = true
        halo.layer?.opacity = 0
        halo.color = Theme.current.chrome.accent.nsColor
        halo.outset = Self.haloOutset
        halo.cornerRadius = Self.cornerRadius
        halo.blur = Self.haloBlur
        halo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(halo)  // below the card, so the glow reads as cast by it
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
        clip.addSubview(ring)  // bottom of the clip: content and header draw over it
        clip.addSubview(content)
        applyBackground()  // also the first touch of `chrome`, which mounts the strips over `content`

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

        updateHeader()  // drawer shows its base header now; a pane's stays hidden until zoom
        updateHalo()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mark the ring for redisplay; it reads the terminal's frame itself, at draw time. Setting
    /// the hole from here instead would read a frame that is still stale: AppKit lays a tree out
    /// top-down, so `content` — a descendant, inside `clip` — has not been positioned yet when
    /// this runs. That shipped a panel whose padding went unpainted until any later layout pass
    /// happened to correct it.
    override func layout() {
        super.layout()
        ring.needsDisplay = true
    }

    /// The background a program set in this panel's own terminal with OSC 11, or nil while the
    /// panel is on the theme's. It reaches the interior fill alone, so the padding around
    /// a repainted terminal matches it instead of ringing it in the theme color. The border, the
    /// focus halo and the header stay on `Theme.current` — a program recolors its pane, not the
    /// chrome around it.
    var backgroundOverride: TerminalColor? {
        didSet {
            guard oldValue != backgroundOverride else { return }
            applyBackground()
        }
    }

    /// Test hook: the focus glow's current strength, 0 while unfocused.
    var haloOpacityForTesting: Float { halo.layer?.opacity ?? -1 }

    /// Test hook: the colors actually painted into the panel's interior — read off the
    /// layer and the ring view rather than off `backgroundOverride`, so a hook that never reaches
    /// the paint fails. `fill` is nil below `background-alpha` 1, where the ring paints instead.
    var paintedBackgroundForTesting: (fill: CGColor?, ring: NSColor) {
        (clip.layer?.backgroundColor, ring.color)
    }

    /// Test hook: the glow's frame and where it sits in the stack. It is a sibling
    /// *beneath* the card that has to reach past the panel's own bounds — get either wrong and
    /// the glow is drawn over the terminal, or clipped to nothing, with focus state still correct.
    var haloGeometryForTesting: (frame: NSRect, isBelowCard: Bool) {
        let haloIndex = subviews.firstIndex(of: halo)
        let paneIndex = subviews.firstIndex(of: pane)
        guard let haloIndex, let paneIndex else { return (halo.frame, false) }
        return (halo.frame, haloIndex < paneIndex)
    }

    /// Test hook: whether the header is present and currently shown.
    var isHeaderVisibleForTesting: Bool { chrome.isHeaderVisibleForTesting }

    /// Test hook: the header's current title + resolved keycap shortcut, for asserting
    /// the zoom content swap. Nil when there's no header.
    var headerContentForTesting: (title: String, shortcut: String)? { chrome.headerContentForTesting }

    /// Test hook: the shortcut the mounted header keycap was built with — stale unless the
    /// header actually rebuilt.
    var builtHeaderKeycapForTesting: String? { chrome.builtHeaderKeycapForTesting }

    var findBarForTesting: FindBarView? { chrome.findBarForTesting }

    /// When true the panel is transparent to the pointer — set while it dissolves out on close, so a
    /// click in the vacated region reaches the surviving pane beneath instead of this dead overlay.
    var isHitTransparent = false
    override func hitTest(_ point: NSPoint) -> NSView? { isHitTransparent ? nil : super.hitTest(point) }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest()
        super.mouseDown(with: event)
    }

    /// Show the header with the meta for the current zoom state, or hide it when this state has none.
    /// One rule for both kinds: a pane (base nil) hides until zoomed, then shows its zoom meta; a
    /// drawer shows its base header and swaps to the zoom variant while zoomed.
    private func updateHeader() {
        chrome.setHeader(modeMeta ?? (isZoomed ? zoomMeta : nil) ?? baseMeta)
    }

    private static var idleBorder: NSColor { Theme.current.chrome.ink(alpha: 0.08) }

    /// Re-apply the live pane border / focus-halo colors after a config change, no relaunch. The
    /// glow's color is set once at init (only its opacity is toggled elsewhere), so it's reset
    /// explicitly; the border color is picked up by re-running `updateHalo()`, which reads
    /// `idleBorder`/`accent` fresh. `applyBackground()` re-reads the live alpha, and the live theme
    /// color unless a program has repainted this panel's terminal (see `backgroundOverride`), and
    /// the header rebuilds its title/keybind against the theme and keymap.
    func reapplyTheme() {
        halo.color = Theme.current.chrome.accent.nsColor
        applyBackground()
        chrome.reapplyTheme()
        updateHalo()
    }

    /// Who paints the panel's interior, which `background-alpha` swaps between two arrangements.
    ///
    /// Solid (the default): the clip fills edge to edge, so the padding ring and the area under
    /// the terminal are one flat color and a redraw gap shows the terminal background.
    ///
    /// Translucent: the clip has to stop filling, or it repaints the terminal background behind a
    /// surface that is now see-through, and nothing shows through. The ring takes over the border
    /// region alone at the same alpha the terminal blends at, so the two read as one surface
    /// instead of the ring sitting a shade lighter. Both values are re-read here rather
    /// than captured at init, so a Settings edit applies live.
    ///
    /// The color is `backgroundOverride` ahead of the theme, so once a program has repainted this
    /// panel's terminal a theme change moves the rest of the chrome and leaves this fill matched to
    /// the grid. Everything else here still follows the theme.
    private func applyBackground() {
        let background = (backgroundOverride ?? Theme.current.chrome.background).nsColor
        let alpha = CGFloat(GeneralConfig.current.backgroundAlpha)
        let isSolid = GeneralConfig.current.terminalBehavior.isBackgroundSolid
        clip.layer?.backgroundColor = isSolid ? background.cgColor : nil
        ring.isHidden = isSolid
        ring.color = background.withAlphaComponent(alpha)
        // The chrome strips inside the pane paint their tint over this same fill, so they read at the
        // pane's alpha rather than blending with the desktop. Solid or not: at alpha 1 this is
        // the fill the clip already had behind them.
        chrome.findBarFill = isSolid ? background : ring.color
    }

    private func updateHalo() {
        guard let layer = pane.layer, let haloLayer = halo.layer else { return }
        // Ease from the live (presentation) value so a focus-nav crossfade falls out — the
        // losing host's glow eases down as the gaining host's eases up. Fast (haloDuration)
        // so it never trails rapid ⌘hjkl nav.
        Motion.ease(
            layer, keyPath: "borderColor",
            to: (isFocused ? Theme.current.chrome.accent.nsColor : Self.idleBorder).cgColor)
        Motion.ease(haloLayer, keyPath: "opacity", to: isFocused ? Self.haloOpacity : 0)
    }
}
