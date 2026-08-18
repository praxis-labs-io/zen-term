import AppKit
import TerminalKit

/// The strips a card grows while a mode is up over its terminal: a header at the top, the find bar
/// at the bottom, and scroll mode's cursor over the grid. Shared by `PanelHostView` (a pane or a
/// drawer) and `SurfaceFloatOverlay` (a tool float), which host the same kind of surface.
final class ModeChrome {
    private let container: NSView
    private let content: NSView
    private let padding: CGFloat

    /// Fires whenever a strip moves the terminal. Flipping a constraint does not mark the host as
    /// needing layout, and the host's padding ring reads the terminal's frame at draw time, so
    /// without this it keeps a hole punched for the height the grid no longer has.
    private let onStripsChanged: () -> Void

    private let cursor = ScrollCursorView()

    private var header: PanelHeader?
    private var headerConstraints: [NSLayoutConstraint] = []
    private var contentTopToHeader: NSLayoutConstraint?
    private let contentTopToContainer: NSLayoutConstraint

    /// Built on the first search over this card and kept for its life. A card that never searches
    /// pays nothing; one that searches twice does not rebuild.
    private var findBar: FindBarView?
    private var findBarConstraints: [NSLayoutConstraint] = []
    private var contentBottomToFindBar: NSLayoutConstraint?
    private let contentBottomToContainer: NSLayoutConstraint

    /// How far a strip sits off the container's own edge, inside the card's padding.
    private static let stripInset: CGFloat = 8

    /// - Parameters:
    ///   - container: the view the strips mount into, already holding `content`.
    ///   - content: the terminal's view. This owns its top and bottom, the host its sides.
    ///   - header: built now when the host always has one, else built on first use.
    init(
        container: NSView, content: NSView, padding: CGFloat, header: PanelMeta?,
        onStripsChanged: @escaping () -> Void
    ) {
        self.container = container
        self.content = content
        self.padding = padding
        self.onStripsChanged = onStripsChanged
        contentTopToContainer = content.topAnchor.constraint(
            equalTo: container.topAnchor, constant: padding)
        contentBottomToContainer = content.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -padding)
        NSLayoutConstraint.activate([contentTopToContainer, contentBottomToContainer])

        // Above the terminal, pinned to it rather than to the container, so its row math is in the
        // surface's own coordinates and the card's padding is already out of the way.
        cursor.translatesAutoresizingMaskIntoConstraints = false
        cursor.isHidden = true
        container.addSubview(cursor)
        NSLayoutConstraint.activate([
            cursor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cursor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cursor.topAnchor.constraint(equalTo: content.topAnchor),
            cursor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if let header { makeHeader(header) }
    }

    /// Wear `meta` in the header, or nil to take it down. A card whose host never passes one gets
    /// its header built here, on the first mode that asks for one.
    func setHeader(_ meta: PanelMeta?) {
        guard let meta else {
            if header != nil { setHeaderShown(false) }
            return
        }
        let view = header ?? makeHeader(meta)
        view.apply(meta)
        setHeaderShown(true)
    }

    /// Show scroll mode's overlay in `state`, or nil to take it down. `metrics` is asked for on
    /// every layout pass, so a resize or a font step moves the band without a second call.
    func setScrollCursor(
        _ state: ScrollCursorView.State?, metrics: @escaping () -> TerminalCellMetrics?
    ) {
        guard let state else {
            cursor.isHidden = true
            cursor.metrics = nil
            cursor.state = nil
            return
        }
        cursor.metrics = metrics
        cursor.state = state
        cursor.isHidden = false
        // Unconditional. See `ScrollCursorView.redraw()` for why an equality check on `state` is
        // the wrong guard.
        cursor.redraw()
    }

    /// Raise or lower the find bar, returning it while it is up so the caller can wire it.
    /// The bar displaces the terminal rather than floating over it, exactly as the header does at
    /// the other end, so the grid reflows and the caller has to lay out and re-measure after this.
    /// See `SearchController.settleLayout()`.
    @discardableResult
    func setFindBarShown(_ shown: Bool) -> FindBarView? {
        defer { onStripsChanged() }
        guard shown else {
            findBar?.isHidden = true
            NSLayoutConstraint.deactivate(findBarConstraints + [contentBottomToFindBar].compactMap { $0 })
            contentBottomToContainer.isActive = true
            return nil
        }
        let bar = findBar ?? makeFindBar()
        bar.isHidden = false
        contentBottomToContainer.isActive = false
        NSLayoutConstraint.activate(findBarConstraints + [contentBottomToFindBar].compactMap { $0 })
        return bar
    }

    /// The fill the strips tint over, so they read at the card's own alpha rather than blending
    /// with whatever is behind the window. The host sets it from its background.
    var findBarFill: NSColor = .clear {
        didSet { findBar?.paneFill = findBarFill }
    }

    /// Rebuild the strips against the live theme and keymap: the header's shortcut is fixed at
    /// build time, so a rebind is reflected by re-resolving it.
    func reapplyTheme() {
        header?.reapplyTheme()
        findBar?.reapplyTheme()
    }

    var scrollCursorForTesting: ScrollCursorView { cursor }
    var findBarForTesting: FindBarView? { findBar?.isHidden == false ? findBar : nil }
    var isHeaderVisibleForTesting: Bool { header.map { !$0.isHidden } ?? false }
    var headerContentForTesting: (title: String, shortcut: String)? { header?.contentForTesting }
    var builtHeaderKeycapForTesting: String? { header?.builtKeycapShortcutForTesting }

    /// Swap between header-above-content and content-at-top, and hide/show the header.
    private func setHeaderShown(_ shown: Bool) {
        guard let header, let contentTopToHeader else { return }
        defer { onStripsChanged() }
        header.isHidden = !shown
        if shown {
            contentTopToContainer.isActive = false
            NSLayoutConstraint.activate(headerConstraints + [contentTopToHeader])
        } else {
            NSLayoutConstraint.deactivate(headerConstraints + [contentTopToHeader])
            contentTopToContainer.isActive = true
        }
    }

    @discardableResult
    private func makeHeader(_ meta: PanelMeta) -> PanelHeader {
        let view = PanelHeader(meta)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        container.addSubview(view)
        headerConstraints = [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.stripInset),
        ]
        contentTopToHeader = content.topAnchor.constraint(
            equalTo: view.bottomAnchor, constant: padding)
        header = view
        return view
    }

    private func makeFindBar() -> FindBarView {
        let bar = FindBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        findBarConstraints = [
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.stripInset),
        ]
        contentBottomToFindBar = content.bottomAnchor.constraint(
            equalTo: bar.topAnchor, constant: -padding)
        findBar = bar
        bar.paneFill = findBarFill  // built on the first search, long after the host set its fill
        return bar
    }
}

/// A muted small-caps title (left) and its live keybind chip (right), e.g. `BOTTOM DRAWER ⌘B`, or
/// `TERMINAL PANE: FOCUS MODE ⌘⇧⏎` while zoomed. The chip resolves from the live keymap via
/// `CommandCatalog`, so it tracks user rebinds.
private final class PanelHeader: NSView {
    private var title: String
    private var action: KeyInterceptor.ReservedChord
    private let titleField = NSTextField(labelWithString: "")
    private var keycap: KeycapView
    private static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)

    /// Test hook: the header's current title text + resolved keycap shortcut, for
    /// asserting the drawer's resting → zoomed swap.
    var contentForTesting: (title: String, shortcut: String) {
        (titleField.stringValue, CommandCatalog.spec(for: action).shortcut)
    }

    /// Test hook: the shortcut the MOUNTED keycap was built with. Unlike `contentForTesting`,
    /// which re-resolves against the live keymap on every read, this is the value actually on
    /// screen — so it goes stale if the rebuild is skipped, which is what makes it usable for
    /// asserting that a rebind reached this header.
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
    /// The keycap rebuilds only when the action moves: a mode header re-applies on every scroll
    /// report, and re-adding a view per keystroke to redraw an unchanged ⌘⇧S is churn for nothing.
    func apply(_ meta: PanelMeta) {
        let actionMoved = action != meta.action
        title = meta.title
        action = meta.action
        applyTitle()
        if actionMoved { rebuildKeycap() }
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
