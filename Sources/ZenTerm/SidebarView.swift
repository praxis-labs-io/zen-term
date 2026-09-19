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

    private let caption = FieldCaption("Workspaces", required: false)
    private let rowStack = NSStackView()
    private var rows: [WorkspaceID: SettingsNavRow] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [caption, rowStack] { addSubview(view) }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding + Self.captionInset),
            caption.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.captionHeight / 2),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.captionHeight),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
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

    func reapplyTheme() {
        caption.reapplyTheme()
        for row in rows.values { row.reapplyTheme() }
    }

    var rowsForTesting: [SettingsNavRow] { rowStack.arrangedSubviews.compactMap { $0 as? SettingsNavRow } }
}
