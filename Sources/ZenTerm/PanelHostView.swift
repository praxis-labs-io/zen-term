import AppKit

/// A panel's top header: a muted small-caps title (left) and its live keybind (right),
/// e.g. `("Bottom drawer", .toggleBottomDrawer)` → `BOTTOM DRAWER  ⌘B`. Replaces the old
/// floating corner icons — a labeled header, not a control; the toggle lives in the footer
/// dock and the keymap.
struct PanelMeta {
    let title: String
    let action: KeyInterceptor.ReservedChord
}

/// Hosts one terminal surface (a pane leaf or a drawer) inside the shared rounded/bordered
/// chrome: the iris focus halo (accent border + soft glow) and an inner clip that keeps
/// content within the corner radius. A drawer passes `meta` for an always-on header, and may
/// also pass `zoomMeta` — the header content it swaps to while zoomed (e.g. its title appended
/// with "— Full screen" and the keybind replaced by ⌘F). A pane passes only `zoomMeta` for a
/// header that appears only while the pane is zoomed (full screen). Panes with neither
/// look/behave exactly as the original pane-only chrome. Clicking anywhere in the panel
/// requests focus.
final class PanelHostView: NSView {
    private let onFocusRequest: () -> Void
    private let pane = ShadowCardView()  // focus glow gets an explicit shadowPath
    private let clip = NSView()  // inner clip so terminal content stays inside the radius
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
    /// full-screen header; a drawer keeps its always-on header but swaps its content to the
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

    init(
        content: NSView, background: NSColor, meta: PanelMeta?, zoomMeta: PanelMeta? = nil,
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
        pane.layer?.cornerRadius = 12
        pane.layer?.masksToBounds = false  // glow must escape bounds; content clip is on a mask below
        pane.layer?.borderWidth = 1
        // The focus glow is a fixed iris shadow whose opacity toggles (animated in
        // updateHalo); its color/radius/offset never change, so set them once here.
        pane.layer?.shadowColor = Theme.current.chrome.accent.nsColor.cgColor
        pane.layer?.shadowRadius = 6
        pane.layer?.shadowOffset = .zero
        addSubview(pane)

        content.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = background.cgColor  // fills the padding ring with the terminal bg
        clip.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(clip)
        clip.addSubview(content)

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

    /// Test hook: whether the header is present and currently shown (ZEN-65).
    var isHeaderVisibleForTesting: Bool { headerView.map { !$0.isHidden } ?? false }

    /// Test hook: the header's current title + resolved keycap shortcut (ZEN-65), for asserting
    /// the zoom content swap. Nil when there's no header.
    var headerContentForTesting: (title: String, shortcut: String)? { headerView?.contentForTesting }

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

    /// Re-apply the live pane border / focus-halo colors after a config change — no relaunch.
    /// The glow's `shadowColor` is set once at init (only its opacity is toggled elsewhere), so
    /// it's reset explicitly; the border color is picked up by re-running `updateHalo()`, which
    /// reads `idleBorder`/`accent` fresh. The clip's padding-ring fill is likewise set once at
    /// init, and the header rebuilds its title/keybind against the live theme and keymap.
    func reapplyTheme() {
        pane.layer?.shadowColor = Theme.current.chrome.accent.nsColor.cgColor
        clip.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        headerView?.reapplyTheme()
        updateHalo()
    }

    private func updateHalo() {
        guard let layer = pane.layer else { return }
        // Ease from the live (presentation) value so a focus-nav crossfade falls out — the
        // losing host's glow eases down as the gaining host's eases up. Fast (haloDuration)
        // so it never trails rapid ⌘hjkl nav.
        Motion.ease(
            layer, keyPath: "borderColor",
            to: (isFocused ? Theme.current.chrome.accent.nsColor : Self.idleBorder).cgColor)
        Motion.ease(layer, keyPath: "shadowOpacity", to: isFocused ? Float(0.3) : Float(0))
    }

    /// A muted small-caps title (left) and its live keybind chip (right), e.g. `BOTTOM DRAWER ⌘B`.
    /// The keybind resolves from the live keymap via `CommandCatalog`, so it tracks user rebinds.
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
