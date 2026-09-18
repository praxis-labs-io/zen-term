import AppKit

struct SidebarRowItem: Equatable {
    let id: WorkspaceID
    let name: String
    let branch: String?
    let isActive: Bool
}

final class SidebarView: NSView {
    static let width: CGFloat = 240
    private static let padding: CGFloat = 8
    private static let captionHeight: CGFloat = 28
    private static let captionInset: CGFloat = 10
    private static let footerInset: CGFloat = 6
    private static let footerButtonSize = NSSize(width: 22, height: 22)
    private static let footerIconPointSize: CGFloat = 11

    let footer = NSView()
    private let caption = FieldCaption("Workspaces", required: false)
    private let rowStack = NSStackView()
    private var rows: [WorkspaceID: SettingsNavRow] = [:]
    private let paletteButton: IconButton
    private let settingsButton: IconButton
    private let toggleButton: IconButton

    init(onPalette: @escaping () -> Void, onSettings: @escaping () -> Void, onToggle: @escaping () -> Void) {
        func button(
            _ symbol: String, _ label: String, _ action: KeyInterceptor.ReservedChord,
            _ onClick: @escaping () -> Void
        ) -> IconButton {
            IconButton(
                symbol: symbol, size: Self.footerButtonSize, pointSize: Self.footerIconPointSize,
                accessibilityLabel: label, shortcut: { CommandCatalog.spec(for: action).shortcut },
                onClick: onClick)
        }
        paletteButton = button("command", "Command palette", .toggleCommandPalette, onPalette)
        settingsButton = button("gearshape", "Settings", .openSettings, onSettings)
        toggleButton = button("sidebar.left", "Toggle sidebar", .toggleSidebar, onToggle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        for view in [caption, rowStack, footer] { addSubview(view) }
        for view in [paletteButton, settingsButton, toggleButton] { footer.addSubview(view) }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding + Self.captionInset),
            caption.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.captionHeight / 2),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.captionHeight),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding + Self.footerInset),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.padding + Self.footerInset)),
            footer.heightAnchor.constraint(equalToConstant: Self.footerButtonSize.height),
            paletteButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            paletteButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            settingsButton.leadingAnchor.constraint(equalTo: paletteButton.trailingAnchor, constant: 2),
            settingsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            toggleButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ items: [SidebarRowItem]) {
        let ids = Set(items.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for (index, item) in items.enumerated() {
            let row = self.row(for: item)
            if rowStack.arrangedSubviews.firstIndex(of: row) != index {
                let isNew = row.superview == nil
                if !isNew { rowStack.removeArrangedSubview(row) }
                rowStack.insertArrangedSubview(row, at: index)
                if isNew { row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }
            }
            row.setDetail(item.branch)
            row.setSelected(item.isActive)
        }
    }

    private func row(for item: SidebarRowItem) -> SettingsNavRow {
        if let row = rows[item.id] { return row }
        let row = SettingsNavRow(title: item.name, isFocusable: false) {}
        rows[item.id] = row
        return row
    }

    func setOpenModal(palette: Bool, settings: Bool) {
        paletteButton.isActive = palette
        settingsButton.isActive = settings
    }

    func reapplyTheme() {
        caption.reapplyTheme()
        for row in rows.values { row.reapplyTheme() }
        for button in [paletteButton, settingsButton, toggleButton] { button.reapplyTheme() }
    }

    var rowsForTesting: [SettingsNavRow] { rowStack.arrangedSubviews.compactMap { $0 as? SettingsNavRow } }
    var paletteButtonForTesting: IconButton { paletteButton }
    var settingsButtonForTesting: IconButton { settingsButton }
    var toggleButtonForTesting: IconButton { toggleButton }
}
