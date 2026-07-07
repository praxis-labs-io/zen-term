import AppKit

/// The `⌘P` repo picker: a modal command palette over the tab's tile region. A dim,
/// rounded backdrop (matching the panel corner radius) with a centered card holding a
/// search field, a scrollable directory list, and a keyboard-hint footer. Fully
/// keyboard-driven — arrows move the selection, Enter opens in a new tab, Shift+Enter
/// replaces the current tab, Esc closes. A backdrop click also dismisses.
final class RepoPickerOverlay: NSView {
    /// (selected directory, replaceCurrentTab). `replaceCurrentTab` is Shift+Enter.
    private let onChoose: (URL, Bool) -> Void
    private let onDismiss: () -> Void

    private let entries: [RepoEntry]
    private var filtered: [RepoEntry]
    private var selected = 0

    private let searchField = NSTextField()
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No directories in ~/dev")
    private var listHeight: NSLayoutConstraint!
    private var rowViews: [RowView] = []

    private static let rowHeight: CGFloat = 32
    private static let maxListHeight: CGFloat = 320
    private static let emptyListHeight: CGFloat = 56

    init(
        entries: [RepoEntry], background: NSColor,
        onChoose: @escaping (URL, Bool) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.filtered = entries
        self.onChoose = onChoose
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true

        // Transparent click-catcher (no dimming) — still dismisses on an outside click.
        let backdrop = BackdropView(onClick: onDismiss)
        backdrop.wantsLayer = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let card = CardView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        // Dark elevation shadow on the card itself (masksToBounds stays off so it isn't
        // clipped); the list clips its own rows, so nothing overflows the rounded corners.
        FloatShadow.applyShadow(to: card)

        // Search row: a magnifier glyph + a borderless field.
        let glyph = NSTextField(labelWithString: "⌕")
        glyph.font = .systemFont(ofSize: 16)
        glyph.textColor = NSColor(white: 1, alpha: 0.4)
        searchField.placeholderString = "Search ~/dev…"
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .white
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let searchRow = NSStackView(views: [glyph, searchField])
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        searchRow.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // List: a flipped document view (top-down scroll coords) holding a vertical stack.
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay  // slim, auto-hiding — narrower than the legacy track
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = doc
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = NSColor(white: 1, alpha: 0.4)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        scrollView.contentView.addSubview(emptyLabel)

        let footer = NSTextField(labelWithString: "↵ new tab   ⇧↵ replace   ↑↓ move   esc close")
        footer.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        footer.textColor = NSColor(white: 1, alpha: 0.35)
        footer.alignment = .center
        footer.translatesAutoresizingMaskIntoConstraints = false
        // Wrap in a container and center vertically: a stretched label cell top-aligns its
        // text, so the hints would otherwise ride the top of the 34pt footer row.
        let footerRow = NSView()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(footer)

        let stack = NSStackView(views: [searchRow, divider, scrollView, footerRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        listHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.maxListHeight)

        // Preferred 560pt width, but `.defaultHigh` so the required ≤0.92×tile cap wins on
        // a narrow window rather than the two conflicting as required constraints.
        let cardWidth = card.widthAnchor.constraint(equalToConstant: 560)
        cardWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerRow.heightAnchor.constraint(equalToConstant: 34),
            footer.leadingAnchor.constraint(equalTo: footerRow.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor),
            footer.centerYAnchor.constraint(equalTo: footerRow.centerYAnchor),
            listHeight,

            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            // Inset the rows so a selected row's highlight keeps a margin from the list
            // edges (and the overlay scroller) instead of touching them.
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.contentView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 24),
        ])

        rebuildRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Make the search field first responder — called by the host after presenting.
    func focusSearchField() { window?.makeFirstResponder(searchField) }

    // MARK: filtering + selection

    private func applyFilter() {
        let q = searchField.stringValue.lowercased()
        if q.isEmpty {
            filtered = entries
        } else {
            filtered =
                entries
                .filter { $0.name.lowercased().contains(q) }
                .sorted { a, b in
                    let ap = a.name.lowercased().hasPrefix(q)
                    let bp = b.name.lowercased().hasPrefix(q)
                    if ap != bp { return ap }  // prefix matches rank first
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
        }
        selected = 0
        rebuildRows()
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = filtered.enumerated().map { i, entry in
            let row = RowView(entry: entry) { [weak self] clickCount in
                guard let self else { return }
                self.selected = i
                self.updateHighlight()
                if clickCount >= 2 { self.activate(replace: false) }
            }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            return row
        }
        emptyLabel.isHidden = !filtered.isEmpty
        // Empty → keep a small fixed height so the "no results" label isn't clipped by a
        // zero-height scroll view.
        listHeight.constant =
            filtered.isEmpty
            ? Self.emptyListHeight
            : min(CGFloat(filtered.count) * Self.rowHeight, Self.maxListHeight)
        updateHighlight()
        scrollSelectedToVisible()
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = max(0, min(filtered.count - 1, selected + delta))
        updateHighlight()
        scrollSelectedToVisible()
    }

    private func updateHighlight() {
        for (i, row) in rowViews.enumerated() { row.isSelected = (i == selected) }
    }

    private func scrollSelectedToVisible() {
        guard rowViews.indices.contains(selected) else { return }
        let y = CGFloat(selected) * Self.rowHeight
        (scrollView.documentView as? FlippedView)?
            .scrollToVisible(CGRect(x: 0, y: y, width: 1, height: Self.rowHeight))
    }

    private func activate(replace: Bool) {
        guard filtered.indices.contains(selected) else { return }
        onChoose(filtered[selected].url, replace)
    }

    // MARK: subviews

    /// A flipped document view so scroll offsets and `scrollToVisible` are top-down.
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// Swallows clicks so a click on the card's empty area doesn't fall through to the
    /// backdrop (which would dismiss).
    private final class CardView: NSView { override func mouseDown(with event: NSEvent) {} }

    /// A dim backdrop; a click anywhere on it (outside the card) dismisses.
    private final class BackdropView: NSView {
        private let onClick: () -> Void
        init(onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func mouseDown(with event: NSEvent) { onClick() }
    }

    /// One directory row: name (left) and a muted git glyph (right) when it's a repo.
    private final class RowView: NSView {
        private let onClick: (Int) -> Void
        var isSelected = false { didSet { updateBackground() } }

        init(entry: RepoEntry, onClick: @escaping (Int) -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6

            let name = NSTextField(labelWithString: entry.name)
            name.font = .systemFont(ofSize: 13)
            name.textColor = .white
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            if entry.isGitRepo {
                let git = NSTextField(labelWithString: "⑂")
                git.font = .systemFont(ofSize: 12)
                git.textColor = NSColor(white: 1, alpha: 0.35)
                git.translatesAutoresizingMaskIntoConstraints = false
                addSubview(git)
                git.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
                git.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func mouseDown(with event: NSEvent) { onClick(event.clickCount) }

        private static let selectedBG = NSColor(
            srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0,
            blue: 0xe7 / 255.0, alpha: 0.18)
        private func updateBackground() {
            layer?.backgroundColor = (isSelected ? Self.selectedBG : .clear).cgColor
        }
    }
}

extension RepoPickerOverlay: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss(); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            activate(replace: shift); return true
        default:
            return false
        }
    }
}
