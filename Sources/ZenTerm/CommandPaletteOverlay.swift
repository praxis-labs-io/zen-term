import AppKit

final class CommandPaletteOverlay: PaletteOverlay {
    private enum Row {
        case header(String)
        case command(PaletteCommand)
    }

    private static let commandHeight: CGFloat = 34

    private let onRun: (KeyInterceptor.ReservedChord) -> Void

    /// Re-resolved rather than snapshotted: a `PaletteCommand` bakes in its shortcut glyph when built.
    private let resolveCommands: () -> [PaletteCommand]
    private var commands: [PaletteCommand]
    private var rows: [Row]

    init(
        commands: @escaping () -> [PaletteCommand], background: NSColor,
        onRun: @escaping (KeyInterceptor.ReservedChord) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.resolveCommands = commands
        let resolved = commands()
        self.commands = resolved
        self.rows = Self.grouped(resolved)
        self.onRun = onRun
        super.init(
            background: background,
            placeholder: "Search commands…",
            emptyText: "No matching commands",
            footerHints: [
                PaletteHint(keys: "⏎", label: "run"),
                PaletteHint(keys: "↑↓", label: "move"),
                PaletteHint(keys: "⎋", label: "close"),
            ],
            rowHeight: Self.commandHeight,
            onDismiss: onDismiss)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func reapplyTheme() {
        commands = resolveCommands()
        super.reapplyTheme()
    }

    var builtRowShortcutsForTesting: [String] {
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        return descendants(of: self).compactMap { $0 as? RowView }
            .flatMap { descendants(of: $0).compactMap { ($0 as? KeycapView)?.shortcut } }
    }

    override func numberOfRows() -> Int { rows.count }

    override func makeRow(at index: Int) -> PaletteRowView {
        switch rows[index] {
        case .header(let title):
            return PaletteSectionHeader(title: title)
        case .command(let command):
            return RowView(command: command)
        }
    }

    /// Includes the shortcut: a user float's title can collide with a built-in command's.
    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .header(let title): return ["header", title]
        case .command(let command): return ["command", command.title, command.shortcut]
        }
    }

    override func rowHeight(at index: Int) -> CGFloat {
        if case .header = rows[index] { return PaletteSectionHeader.height }
        return Self.commandHeight
    }

    override func isSelectable(at index: Int) -> Bool {
        if case .command = rows[index] { return true }
        return false
    }

    /// A category-only hit ranks below every title hit, so it never preselects a command the query did not name.
    override func applyFilter(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            rows = Self.grouped(commands)
        } else {
            rows =
                commands
                .compactMap { command -> (command: PaletteCommand, isTitleMatch: Bool, score: Int)? in
                    if let titleScore = FuzzyMatch.score(q, command.title) {
                        return (command, true, titleScore)
                    }
                    if let categoryScore = FuzzyMatch.score(q, command.category) {
                        return (command, false, categoryScore)
                    }
                    return nil
                }
                .sorted { a, b in
                    if a.isTitleMatch != b.isTitleMatch { return a.isTitleMatch }
                    if a.score != b.score { return a.score > b.score }
                    return a.command.title.localizedCaseInsensitiveCompare(b.command.title) == .orderedAscending
                }
                .map { .command($0.command) }
        }
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index), case .command(let command) = rows[index] else { return }
        onRun(command.chord)
    }

    private static func grouped(_ commands: [PaletteCommand]) -> [Row] {
        var rows: [Row] = []
        var current: String?
        for command in commands {
            if command.category != current {
                rows.append(.header(command.category))
                current = command.category
            }
            rows.append(.command(command))
        }
        return rows
    }

    private final class RowView: SelectableRowView {
        init(command: PaletteCommand) {
            super.init()

            let title = NSTextField(labelWithString: command.title)
            title.font = .systemFont(ofSize: 13)
            title.textColor = Theme.current.chrome.foreground.nsColor
            title.translatesAutoresizingMaskIntoConstraints = false
            addSubview(title)

            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            guard !command.shortcut.isEmpty else { return }
            let keycap = KeycapView(shortcut: command.shortcut)
            addSubview(keycap)
            NSLayoutConstraint.activate([
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -8),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
