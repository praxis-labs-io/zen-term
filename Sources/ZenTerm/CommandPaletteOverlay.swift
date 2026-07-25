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
            return RowView(command: command)
        }
    }

    /// A row is the same row across a re-filter when it names the same section, or the same command
    /// with the same shortcut. The identity has to cover everything the row renders, and a command
    /// row renders both: a tool float's title comes from user config and nothing stops it colliding
    /// with a built-in command's, so keying on the title alone would let one row inherit the other's
    /// keycap and show a chord that doesn't run it.
    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .header(let title): return ["header", title]
        case .command(let command): return ["command", command.title, command.shortcut]
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
                .compactMap { command -> (command: PaletteCommand, isTitleMatch: Bool, score: Int)? in
                    // Match the section name too, so `config` surfaces the whole Config section and
                    // `panes` the whole Panes section — but a category-only hit ranks *below* every
                    // title hit, so it can never preselect (and Enter-run) a command the query
                    // didn't name, even when the category scores higher than a weak title match.
                    if let titleScore = FuzzyMatch.score(q, command.title) {
                        return (command, true, titleScore)
                    }
                    if let categoryScore = FuzzyMatch.score(q, command.category) {
                        return (command, false, categoryScore)
                    }
                    return nil
                }
                .sorted { a, b in
                    if a.isTitleMatch != b.isTitleMatch { return a.isTitleMatch }  // title matches first
                    if a.score != b.score { return a.score > b.score }  // then higher score
                    return a.command.title.localizedCaseInsensitiveCompare(b.command.title) == .orderedAscending
                }
                .map { .command($0.command) }  // flat, no headers while searching
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
        var onActivate: (() -> Void)?  // headers aren't selectable, so this is never run

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

            // A command with no bound shortcut skips the keycap rather than render an empty pill.
            guard !command.shortcut.isEmpty else { return }
            let keycap = KeycapView(shortcut: command.shortcut)
            addSubview(keycap)
            NSLayoutConstraint.activate([
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
                // Keep the title from colliding with the keycap on a narrow card.
                title.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -8),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
