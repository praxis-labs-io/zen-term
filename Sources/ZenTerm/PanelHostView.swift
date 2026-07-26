import AppKit

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
/// "<panel>: Focus Mode" and the keybind replaced by ⌘F). A pane passes only `zoomMeta` for a
/// header that appears only while the pane is zoomed (Focus Mode). Panes with neither
/// look/behave exactly as the original pane-only chrome. Clicking anywhere in the panel
/// requests focus.
final class PanelHostView: NSView {
    private let onFocusRequest: () -> Void
    private let pane = NSView()  // the bordered card; the glow is cast by `halo`, not by a shadow
    private let clip = NSView()  // inner clip so terminal content stays inside the radius
    private let ring = RingFillView()  // paints the padding ring once the clip stops filling it
    private let halo = HaloView()  // the focus glow, cast around the card from beneath it
    private let headerView: PanelHeader?
    /// The header content for the resting vs zoomed state. A pane has only `zoomMeta` (header hidden
    /// until zoomed); a drawer has both (its base header ⇄ the zoom variant). `updateHeader` picks
    /// the meta for the current zoom state — `(isZoomed ? zoomMeta : nil) ?? baseMeta`, nil meta
    /// hides — which covers both cases in one rule.
    private let baseMeta: PanelMeta?
    private let zoomMeta: PanelMeta?
    private var headerTopConstraints: [NSLayoutConstraint] = []
    private var contentTopToHeader: NSLayoutConstraint?
    private var contentTopToClip: NSLayoutConstraint?

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

    init(
        content: NSView, meta: PanelMeta?, zoomMeta: PanelMeta? = nil,
        onFocusRequest: @escaping () -> Void
    ) {
        self.onFocusRequest = onFocusRequest
        self.baseMeta = meta
        self.zoomMeta = zoomMeta
        // Construct with whichever meta exists; `updateHeader()` below sets the state-correct one.
        headerView = (meta ?? zoomMeta).map(PanelHeader.init)
        super.init(frame: .zero)

        wantsLayer = true
        pane.wantsLayer = true
        pane.layer?.cornerRadius = Self.cornerRadius
        pane.layer?.masksToBounds = false  // content is clipped by `clip` below, not by the card
        pane.layer?.borderWidth = 1
        // The focus glow is its own view beneath the card, not a shadow on the card — see
        // HaloView. Its color is fixed; only its opacity toggles (animated in updateHalo).
        halo.wantsLayer = true
        halo.layer?.opacity = 0
        halo.color = Theme.current.chrome.accent.nsColor
        halo.outset = Self.haloOutset
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
        ring.contentView = content
        clip.addSubview(ring)  // bottom of the clip: content and header draw over it
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
            content.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -padding),
        ])

        contentTopToClip = content.topAnchor.constraint(equalTo: clip.topAnchor, constant: padding)
        if let headerView {
            headerView.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(headerView)
            headerTopConstraints = [
                headerView.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: padding),
                headerView.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -padding),
                headerView.topAnchor.constraint(equalTo: clip.topAnchor, constant: 8),
            ]
            contentTopToHeader = content.topAnchor.constraint(
                equalTo: headerView.bottomAnchor, constant: padding)
            updateHeader()  // drawer shows its base header now; a pane's stays hidden until zoom
        } else {
            contentTopToClip?.isActive = true
        }

        updateHalo()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mark the ring for redisplay; it reads the terminal's frame itself, at draw time. Setting
    /// the hole from here instead would read a frame that is still stale: AppKit lays a tree out
    /// top-down, so `content` — a descendant, inside `clip` — has not been positioned yet when
    /// this runs. That shipped a panel whose padding went unpainted until any later layout pass
    /// happened to correct it (ZEN-282).
    override func layout() {
        super.layout()
        ring.needsDisplay = true
    }

    /// Test hook: the focus glow's current strength (ZEN-282), 0 while unfocused.
    var haloOpacityForTesting: Float { halo.layer?.opacity ?? -1 }

    /// Test hook: the glow's frame and where it sits in the stack (ZEN-282). It is a sibling
    /// *beneath* the card that has to reach past the panel's own bounds — get either wrong and
    /// the glow is drawn over the terminal, or clipped to nothing, with focus state still correct.
    var haloGeometryForTesting: (frame: NSRect, isBelowCard: Bool) {
        let haloIndex = subviews.firstIndex(of: halo)
        let paneIndex = subviews.firstIndex(of: pane)
        guard let haloIndex, let paneIndex else { return (halo.frame, false) }
        return (halo.frame, haloIndex < paneIndex)
    }

    /// Test hook: whether the header is present and currently shown (ZEN-65).
    var isHeaderVisibleForTesting: Bool { headerView.map { !$0.isHidden } ?? false }

    /// Test hook: the header's current title + resolved keycap shortcut (ZEN-65), for asserting
    /// the zoom content swap. Nil when there's no header.
    var headerContentForTesting: (title: String, shortcut: String)? { headerView?.contentForTesting }

    /// Test hook: the shortcut the mounted header keycap was built with — stale unless the
    /// header actually rebuilt (ZEN-48).
    var builtHeaderKeycapForTesting: String? { headerView?.builtKeycapShortcutForTesting }

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
        guard let headerView else { return }
        if let meta = (isZoomed ? zoomMeta : nil) ?? baseMeta {
            headerView.apply(meta)
            setHeaderShown(true)
        } else {
            setHeaderShown(false)
        }
    }

    /// Swap between header-above-content and content-at-top, and hide/show the header.
    private func setHeaderShown(_ shown: Bool) {
        guard let headerView, let contentTopToHeader, let contentTopToClip else { return }
        headerView.isHidden = !shown
        if shown {
            contentTopToClip.isActive = false
            NSLayoutConstraint.activate(headerTopConstraints + [contentTopToHeader])
        } else {
            NSLayoutConstraint.deactivate(headerTopConstraints + [contentTopToHeader])
            contentTopToClip.isActive = true
        }
    }

    private static var idleBorder: NSColor { Theme.current.chrome.ink(alpha: 0.08) }

    /// Re-apply the live pane border / focus-halo colors after a config change, no relaunch. The
    /// glow's color is set once at init (only its opacity is toggled elsewhere), so it's reset
    /// explicitly; the border color is picked up by re-running `updateHalo()`, which reads
    /// `idleBorder`/`accent` fresh. `applyBackground()` re-reads the live alpha as well as the
    /// live color, and the header rebuilds its title/keybind against the theme and keymap.
    func reapplyTheme() {
        halo.color = Theme.current.chrome.accent.nsColor
        applyBackground()
        headerView?.reapplyTheme()
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
    /// instead of the ring sitting a shade lighter (ZEN-282). Both values are re-read here rather
    /// than captured at init, so a Settings edit applies live.
    private func applyBackground() {
        let background = Theme.current.chrome.background.nsColor
        let alpha = CGFloat(GeneralConfig.current.backgroundAlpha)
        let isSolid = GeneralConfig.current.terminalBehavior.isBackgroundSolid
        clip.layer?.backgroundColor = isSolid ? background.cgColor : nil
        ring.isHidden = isSolid
        ring.color = background.withAlphaComponent(alpha)
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

    /// The focus glow, drawn around the card rather than cast by it.
    ///
    /// It used to be a `shadowOpacity` on the card's own layer, which Core Animation renders by
    /// *filling* `shadowPath` — so the accent covered the card's whole interior as well as
    /// haloing it. That was free while the panel was opaque and painted over it, and became a
    /// wash across the pane the moment `background-alpha` made it see-through (ZEN-282).
    ///
    /// Reshaping the path into a ring doesn't work: a drop shadow decays outward *from* a filled
    /// silhouette, so a ring makes the glow ramp up as it travels out instead of fading, landing
    /// as a huge dense cloud. The silhouette has to stay the card, and the cut has to happen at
    /// draw time — hence the clip below, which keeps the falloff exactly as it was and removes
    /// only the half that fell inside.
    private final class HaloView: NSView {
        /// Measured falloff from the card edge, before `haloOpacity`: 6 peaks at 0.118 alpha and
        /// dies by 6pt, 12 peaks at 0.133 and carries to 10pt. 8 sits between them, reaching far
        /// enough to read as a glow without the purple wash the wider end spreads around a pane.
        private static let blur: CGFloat = 8

        var color: NSColor = .clear { didSet { needsDisplay = true } }
        /// How far this view is outset past the card it glows around, i.e. the inset from its own
        /// bounds back to the card's edge.
        var outset: CGFloat = 0 { didSet { needsDisplay = true } }

        /// Decoration only — never take a click off the panel beneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let card = bounds.insetBy(dx: outset, dy: outset)
            guard card.width > 0, card.height > 0 else { return }
            let radius = min(PanelHostView.cornerRadius, card.width / 2, card.height / 2)
            let path = CGPath(
                roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

            context.saveGState()
            context.addRect(bounds)
            context.addPath(path)
            context.clip(using: .evenOdd)  // everything except the card itself
            context.setShadow(offset: .zero, blur: Self.blur, color: color.cgColor)
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath()  // clipped away; only the shadow it throws survives
            context.restoreGState()
        }
    }

    /// The panel's inner padding, painted as a rounded rect with the terminal content punched out
    /// of it. A view rather than a `CAShapeLayer` hand-inserted under the clip's own sublayers,
    /// where AppKit owns the ordering and a later subview insertion can reshuffle it.
    private final class RingFillView: NSView {
        var color: NSColor = .clear { didSet { needsDisplay = true } }
        /// The terminal, whose frame is the part left unpainted. Read at draw time rather than
        /// stored, because layout runs top-down and this view's owner is laid out first — see
        /// `PanelHostView.layout()`.
        weak var contentView: NSView?

        override func draw(_ dirtyRect: NSRect) {
            guard let contentView, let superview else { return }
            let hole = convert(contentView.frame, from: superview)
            let path = NSBezierPath(
                roundedRect: bounds, xRadius: PanelHostView.cornerRadius,
                yRadius: PanelHostView.cornerRadius)
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
            color.setFill()
            path.fill()
        }
    }

    /// A muted small-caps title (left) and its live keybind chip (right), e.g. `BOTTOM DRAWER ⌘B`,
    /// or `TERMINAL PANE: FOCUS MODE ⌘F` while zoomed. The keybind resolves from the live keymap via
    /// `CommandCatalog`, so it tracks user rebinds.
    private final class PanelHeader: NSView {
        private var title: String
        private var action: KeyInterceptor.ReservedChord
        private let titleField = NSTextField(labelWithString: "")
        private var keycap: KeycapView
        private static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

        /// Test hook: the header's current title text + resolved keycap shortcut (ZEN-65), for
        /// asserting the drawer's resting → zoomed swap.
        var contentForTesting: (title: String, shortcut: String) {
            (titleField.stringValue, CommandCatalog.spec(for: action).shortcut)
        }

        /// Test hook: the shortcut the MOUNTED keycap was built with. Unlike `contentForTesting`,
        /// which re-resolves against the live keymap on every read, this is the value actually on
        /// screen — so it goes stale if the rebuild is skipped, which is what makes it usable for
        /// asserting that a rebind reached this header (ZEN-48).
        var builtKeycapShortcutForTesting: String { keycap.shortcut }

        init(_ meta: PanelMeta) {
            title = meta.title
            action = meta.action
            keycap = KeycapView(shortcut: CommandCatalog.spec(for: meta.action).shortcut, showsBackground: false)
            super.init(frame: .zero)
            titleField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(titleField)
            addSubview(keycap)
            NSLayoutConstraint.activate([
                titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 20),
            ])
            activateKeycapConstraints()
            applyTitle()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Swap the header to a new title + keybind (a drawer's resting → zoomed transition).
        func apply(_ meta: PanelMeta) {
            title = meta.title
            action = meta.action
            applyTitle()
            rebuildKeycap()
        }

        /// Re-apply the live title ink and rebuild the keybind chip — its shortcut is fixed at
        /// build time, so a rebind (or theme swap) is reflected by re-resolving from the keymap.
        func reapplyTheme() {
            applyTitle()
            rebuildKeycap()
        }

        /// Rebuild the keycap from the current `action` against the live keymap.
        private func rebuildKeycap() {
            keycap.removeFromSuperview()
            keycap = KeycapView(shortcut: CommandCatalog.spec(for: action).shortcut, showsBackground: false)
            addSubview(keycap)
            activateKeycapConstraints()
        }

        private func activateKeycapConstraints() {
            keycap.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
                keycap.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 8),
            ])
        }

        private func applyTitle() {
            titleField.attributedStringValue = NSAttributedString(
                string: title.uppercased(),
                attributes: [
                    .font: Self.font,
                    .foregroundColor: Theme.current.chrome.ink(alpha: 0.4),
                    .kern: 1.2,
                ])
        }
    }
}
