import AppKit

// Everything a reveal brings on screen: the rows and footer, and the card chrome they float behind.
final class SidebarColumn: ShadowCardView {
    let rows: SidebarView
    let footer: SidebarFooter
    private let blur = NSVisualEffectView()
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
        blur.material = .hudWindow
        // Within-window, unlike the window's own backdrop: what sits behind this card is a pane, not the desktop.
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.isHidden = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        for child in [blur, rows, footer] as [NSView] { addSubview(child) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SidebarView.width),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    func setFloating(_ floating: Bool) {
        isFloating = floating
        // The shadow needs an unclipped layer, so the radius has to be clipped on the content instead.
        rows.wantsLayer = true
        rows.layer?.cornerRadius = floating ? CardChrome.cornerRadius : 0
        rows.layer?.masksToBounds = floating
        blur.isHidden = !floating
        blur.layer?.cornerRadius = floating ? CardChrome.cornerRadius : 0
        blur.layer?.masksToBounds = floating
        guard floating else {
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
            shadow = nil
            return
        }
        CardChrome.apply(to: self, background: Self.cardFill)
    }

    // Docked, the rows sit on the window's own backdrop, so floating they carry the same tint rather than a slab.
    private static var cardFill: NSColor {
        Theme.current.chrome.background.nsColor.withAlphaComponent(GeneralConfig.current.backdropAlpha)
    }

    func setContentHidden(_ hidden: Bool) {
        rows.isHidden = hidden
        footer.isHidden = hidden
    }

    func reapplyTheme() {
        rows.reapplyTheme()
        footer.reapplyTheme()
        if isFloating { CardChrome.apply(to: self, background: Self.cardFill) }
    }
}
