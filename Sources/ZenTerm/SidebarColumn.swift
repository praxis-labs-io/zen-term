import AppKit

// Everything a reveal brings on screen: the rows and footer, and the card chrome they float behind.
final class SidebarColumn: ShadowCardView {
    // 8 of sidebar padding plus the footer's 6 inset, so palette and Settings follow at the footer's rhythm.
    static let toggleInset: CGFloat = 14

    let rows: SidebarView
    let footer: SidebarFooter
    let toggle: IconButton
    // Every other side moved inward with the card and took the window's gutter along; the top edge stays put.
    private(set) var contentTop: NSLayoutConstraint?
    private(set) var isFloating = false

    init(
        onPalette: @escaping () -> Void, onSettings: @escaping () -> Void, onToggle: @escaping () -> Void,
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (SidebarRowID) -> Void,
        onCloseWorkspace: @escaping (WorkspaceID) -> Void, onAdd: @escaping () -> Void
    ) {
        rows = SidebarView(
            onActivate: onActivate, onNewWorktree: onNewWorktree, onCloseWorkspace: onCloseWorkspace, onAdd: onAdd)
        footer = SidebarFooter(onPalette: onPalette, onSettings: onSettings)
        toggle = SidebarFooter.button("sidebar.left", "Toggle sidebar", .toggleSidebar, onToggle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for child in [rows, footer, toggle] as [NSView] { addSubview(child) }
        let contentTop = rows.topAnchor.constraint(equalTo: topAnchor)
        self.contentTop = contentTop
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SidebarView.width),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentTop,
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.toggleInset),
            toggle.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -TabBarView.chipBandInset),
            footer.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: SidebarFooter.spacing),
            footer.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
        ])
        rows.limitContent(above: toggle.topAnchor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Collapsed the column is an empty frame over the canvas, and a plain NSView would still eat the clicks.
    // Faded out it is the same thing: the rows only hide when the fade lands, a whole slide later.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard layer?.opacity ?? 1 > 0 else { return nil }
        let hit = super.hitTest(point)
        return hit === self && rows.isHidden ? nil : hit
    }

    // The card sits at the window gutter exactly as the panes do, so it takes the corner they resolve against it.
    static var cornerRadius: CGFloat { PanelHostView.cornerRadius }

    func setFloating(_ floating: Bool) {
        isFloating = floating
        contentTop?.constant = floatingContentTop
        // The shadow needs an unclipped layer, so the radius has to be clipped on the content instead.
        rows.wantsLayer = true
        rows.layer?.cornerRadius = floating ? Self.cornerRadius : 0
        rows.layer?.masksToBounds = floating
        guard floating else {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
            shadow = nil
            return
        }
        CardChrome.apply(
            to: self, background: Theme.current.chrome.background.nsColor, cornerRadius: Self.cornerRadius)
    }

    var floatingContentTop: CGFloat { isFloating ? ChromeMetrics.windowGutter : 0 }

    func reapplyCornerRadius() {
        guard isFloating else { return }
        contentTop?.constant = floatingContentTop
        layer?.cornerRadius = Self.cornerRadius
        rows.layer?.cornerRadius = Self.cornerRadius
        needsLayout = true
    }

    func setContentHidden(_ hidden: Bool) {
        rows.isHidden = hidden
        footer.isHidden = hidden
    }

    // The window keeps a toggle of its own for the collapsed sidebar, so only one of the two is ever on screen.
    func setToggleHidden(_ hidden: Bool) { toggle.isHidden = hidden }

    func reapplyTheme() {
        rows.reapplyTheme()
        footer.reapplyTheme()
        toggle.reapplyTheme()
        if isFloating { CardChrome.reapplyTheme(to: self) }
    }
}
