import AppKit

/// The `⌘P` command palette: a modal, fuzzy-searchable list of every chrome action bound
/// to a keyboard shortcut, each row showing its shortcut in a keycap box. Enter runs the
/// selected command, Esc / backdrop click dismiss. Built on `PaletteOverlay`.
///
/// Unfiltered, the list is grouped under muted section headers (Panes, Tabs, …). Typing
/// collapses it to a single fuzzy-ranked list with no headers — ranking crosses groups, so
/// headers would no longer bound anything.
final class CommandPaletteOverlay: PaletteOverlay {
    private enum Row {
        case header(String)
        case command(PaletteCommand)
    }

    private static let headerHeight: CGFloat = 26
    private static let commandHeight: CGFloat = 34

    private let onRun: (KeyInterceptor.ReservedChord) -> Void

    private let commands: [PaletteCommand]
    private var rows: [Row]

    init(
        commands: [PaletteCommand], background: NSColor,
        onRun: @escaping (KeyInterceptor.ReservedChord) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.commands = commands
        self.rows = Self.grouped(commands)
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

    override func numberOfRows() -> Int { rows.count }

    override func makeRow(at index: Int) -> PaletteRowView {
        switch rows[index] {
        case .header(let title):
            return HeaderRowView(title: title)
        case .command(let command):
            return RowView(command: command) { [weak self] clickCount in
                self?.selectRow(at: index, clickCount: clickCount)
            }
        }
    }

    override func rowHeight(at index: Int) -> CGFloat {
        if case .header = rows[index] { return Self.headerHeight }
        return Self.commandHeight
    }

    override func isSelectable(at index: Int) -> Bool {
        if case .command = rows[index] { return true }
        return false
    }

    override func applyFilter(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            rows = Self.grouped(commands)  // no query → grouped, with headers
        } else {
            rows =
                commands
                .compactMap { command -> (PaletteCommand, Int)? in
                    FuzzyMatch.score(q, command.title).map { (command, $0) }
                }
                .sorted { a, b in
                    if a.1 != b.1 { return a.1 > b.1 }  // higher score first
                    return a.0.title.localizedCaseInsensitiveCompare(b.0.title) == .orderedAscending
                }
                .map { .command($0.0) }  // flat, no headers while searching
        }
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index), case .command(let command) = rows[index] else { return }
        onRun(command.chord)
    }

    /// Insert a header row wherever the category changes, preserving `commands` order.
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

    /// A muted, small-caps section header. Non-selectable — the base skips it.
    private final class HeaderRowView: NSView, PaletteRowView {
        var isSelected = false  // headers never highlight

        init(title: String) {
            super.init(frame: .zero)
            let label = NSTextField(
                labelWithAttributedString: NSAttributedString(
                    string: title.uppercased(),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                        .foregroundColor: Theme.current.chrome.ink(alpha: 0.4),
                        .kern: 0.6,
                    ]))
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                // Sit toward the bottom of the row so the header reads as a lead-in to the
                // group below it rather than floating between two groups.
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// One command row: the action name (left) and its shortcut keycap (right).
    private final class RowView: SelectableRowView {
        init(command: PaletteCommand, onClick: @escaping (Int) -> Void) {
            super.init(onClick: onClick)

            let title = NSTextField(labelWithString: command.title)
            title.font = .systemFont(ofSize: 13)
            title.textColor = Theme.current.chrome.foreground.nsColor
            title.translatesAutoresizingMaskIntoConstraints = false
            addSubview(title)

            let keycap = KeycapView(shortcut: command.shortcut)
            addSubview(keycap)

            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
                // Keep the title from colliding with the keycap on a narrow card.
                title.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -8),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
