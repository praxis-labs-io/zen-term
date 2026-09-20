import AppKit

// The rows, footer and toggle the sidebar shows, held together so they dock flush or float as one card.
final class SidebarColumn: ShadowCardView {
    // 8 of sidebar padding plus the footer's 6 inset, so palette and Settings follow at the footer's rhythm.
    static let toggleInset: CGFloat = 14

    let rows: SidebarView
    let footer: SidebarFooter
    let toggleButton: IconButton

    init(
        onPalette: @escaping () -> Void, onSettings: @escaping () -> Void, onToggle: @escaping () -> Void,
        onActivate: @escaping (SidebarRowID) -> Void, onNewWorktree: @escaping (SidebarRowID) -> Void,
        onCloseWorkspace: @escaping (WorkspaceID) -> Void, onAdd: @escaping () -> Void
    ) {
        rows = SidebarView(
            onActivate: onActivate, onNewWorktree: onNewWorktree, onCloseWorkspace: onCloseWorkspace, onAdd: onAdd)
        footer = SidebarFooter(onPalette: onPalette, onSettings: onSettings)
        toggleButton = SidebarFooter.button("sidebar.left", "Toggle sidebar", .toggleSidebar, onToggle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for child in [rows, footer, toggleButton] as [NSView] { addSubview(child) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SidebarView.width),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.toggleInset),
            footer.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: SidebarFooter.spacing),
            footer.centerYAnchor.constraint(equalTo: toggleButton.centerYAnchor),
        ])
        rows.limitContent(above: toggleButton.topAnchor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func alignToggle(with tabBar: TabBarView) {
        toggleButton.centerYAnchor.constraint(equalTo: tabBar.chipBandCenterYAnchor).isActive = true
    }

    // Collapsed the column is an empty frame over the canvas, and a plain NSView would still eat the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self && rows.isHidden ? nil : hit
    }

    func setContentHidden(_ hidden: Bool) {
        rows.isHidden = hidden
        footer.isHidden = hidden
    }

    func reapplyTheme() {
        rows.reapplyTheme()
        footer.reapplyTheme()
        toggleButton.reapplyTheme()
    }
}
