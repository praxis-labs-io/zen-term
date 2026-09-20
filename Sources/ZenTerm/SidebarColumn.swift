import AppKit

// Everything a reveal brings on screen: the rows and footer, and the card chrome they float behind.
final class SidebarColumn: ShadowCardView {
    let rows: SidebarView
    let footer: SidebarFooter
    private(set) var isFloating = false

    init(
        onPalette: @escaping () -> Void, onSettings: @escaping () -> Void,
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (SidebarRowID) -> Void,
        onCloseWorkspace: @escaping (WorkspaceID) -> Void, onAdd: @escaping () -> Void
    ) {
        rows = SidebarView(
            onActivate: onActivate, onNewWorktree: onNewWorktree, onCloseWorkspace: onCloseWorkspace, onAdd: onAdd)
        footer = SidebarFooter(onPalette: onPalette, onSettings: onSettings)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for child in [rows, footer] as [NSView] { addSubview(child) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SidebarView.width),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Collapsed the column is an empty frame over the canvas, and a plain NSView would still eat the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self && rows.isHidden ? nil : hit
    }

    // The card sits at the window gutter exactly as the panes do, so it takes the corner they resolve against it.
    static var cornerRadius: CGFloat { PanelHostView.cornerRadius }

    func setFloating(_ floating: Bool) {
        isFloating = floating
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

    func reapplyCornerRadius() {
        guard isFloating else { return }
        layer?.cornerRadius = Self.cornerRadius
        rows.layer?.cornerRadius = Self.cornerRadius
        needsLayout = true
    }

    func setContentHidden(_ hidden: Bool) {
        rows.isHidden = hidden
        footer.isHidden = hidden
    }

    func reapplyTheme() {
        rows.reapplyTheme()
        footer.reapplyTheme()
        if isFloating { CardChrome.reapplyTheme(to: self) }
    }
}
