import AppKit

/// The diff viewer: a chrome-native modal card over the active tile. The left column is a single file
/// tree split into three sections — Unstaged, Staged, Committed (top to bottom) — the right column is
/// the side-by-side diff of the selected file, and a full-width footer carries the totals and the key
/// hints. A `ModalOverlay` sharing the card + backdrop + spring and Esc model with the other
/// overlays. Git work is injected as `loader`; the caller only opens this over a real repo (a non-repo
/// shows a toast), so there is no not-a-repo state.
///
/// Navigation uses the app's pane chords rather than Tab: ⌘h/⌘l move between the tree and the diff,
/// ⌘j/⌘k jump to the next/previous change (file in the tree, hunk in the diff). Those arrive through
/// `handleNavChord` (WindowController forwards them, since KeyInterceptor consumes chords before the
/// responder chain). Plain arrows move line-by-line; Left/Right fold sections and directories.
///
/// The `FileDiff` -> side-by-side rows step lives in `SideBySideDiff`; ZEN-228's unified layout swaps
/// that transform, not this shell.
final class DiffViewerOverlay: NSView, ModalOverlay {
    typealias StatusResult = Result<GitDiffRunner.StatusLoad, GitDiffRunner.Failure>
    /// Loads the repo status and calls back on the main thread. Injected so the overlay never touches
    /// `Process` itself; `WindowController` wires this to a `GitDiffRunner`.
    typealias Loader = (@escaping (StatusResult) -> Void) -> Void

    private let loader: Loader
    private let onCancel: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()

    private let outline = NavOutlineView()
    private var outlineController: DiffTreeOutlineController?
    private let treeRule = NSView()
    private let diffTable = DiffPaneTable()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let footerDivider = NSView()
    private let statsLabel = NSTextField(labelWithString: "")
    private let hintsLabel = NSTextField(labelWithString: "")

    private var selectedFilePath: String?
    /// The status currently on screen — a background refresh that returns the same thing is a no-op,
    /// so a reopen from the same dir doesn't yank the view (or flash) when nothing has changed.
    private var displayedStatus: GitDiffRunner.StatusLoad?
    /// Guards against a slower older load overwriting a newer one.
    private var loadToken = 0

    init(
        background: NSColor, initialStatus: GitDiffRunner.StatusLoad?, loader: @escaping Loader,
        onCancel: @escaping () -> Void
    ) {
        self.loader = loader
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onCancel)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        buildLayout()

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            aspect(card.widthAnchor, to: widthAnchor, 0.85, priority: .defaultHigh),
            aspect(card.heightAnchor, to: heightAnchor, 0.85, priority: .defaultHigh),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),
        ])

        // Warm open: render the cached status instantly and refresh silently behind it. Cold open:
        // show the spinner while the first load runs.
        if let initialStatus {
            apply(initialStatus)
            reload(showSpinner: false)
        } else {
            reload(showSpinner: true)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func aspect(
        _ anchor: NSLayoutDimension, to other: NSLayoutDimension, _ multiplier: CGFloat,
        priority: NSLayoutConstraint.Priority
    ) -> NSLayoutConstraint {
        let constraint = anchor.constraint(equalTo: other, multiplier: multiplier)
        constraint.priority = priority
        return constraint
    }

    // MARK: ModalOverlay

    func focusInitialResponder() {
        // The tree always exists and always takes focus, so keystrokes never fall through to the
        // terminal behind the card (even while loading or when there are no changes).
        window?.makeFirstResponder(outline)
    }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        treeRule.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        footerDivider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        messageLabel.textColor = Theme.current.chrome.muted.nsColor
        hintsLabel.attributedStringValue = Self.hintsText()
        if let status = displayedStatus { statsLabel.attributedStringValue = Self.statsText(for: status) }
        outline.reloadData()
        diffTable.reapplyTheme()
    }

    // MARK: pane-chord navigation

    /// The pane-nav chords, forwarded by `WindowController` while this overlay is open (KeyInterceptor
    /// consumes chords before the responder chain, so the overlay can't see them itself). ⌘h/⌘l move
    /// between the tree and the diff; ⌘j/⌘k jump to the next/previous change in the focused pane.
    /// Returns true when it consumed the chord.
    func handleNavChord(_ chord: KeyInterceptor.ReservedChord) -> Bool {
        switch chord {
        case .navLeft:
            window?.makeFirstResponder(outline)
        case .navRight:
            window?.makeFirstResponder(diffTable.scrollFocusTarget)
        case .navDown:
            if treeIsFocused { moveFileSelection(1) } else { diffTable.jumpToNextChange() }
        case .navUp:
            if treeIsFocused { moveFileSelection(-1) } else { diffTable.jumpToPrevChange() }
        default:
            return false
        }
        return true
    }

    private var treeIsFocused: Bool { window?.firstResponder === outline }

    /// Move the tree selection to the next / previous file, skipping section headers and directories.
    private func moveFileSelection(_ delta: Int) {
        let count = outline.numberOfRows
        var row = outline.selectedRow + delta
        while row >= 0, row < count {
            if let item = outline.item(atRow: row) as? DiffOutlineItem, item.fileDiff != nil {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return
            }
            row += delta
        }
    }

    // MARK: layout

    private func buildLayout() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.focusRingType = .none  // no system-blue ring on focus-in (ZEN-27: chrome is theme-only)
        outline.onEscape = { [weak self] in self?.onCancel() }
        diffTable.onEscape = { [weak self] in self?.onCancel() }

        let treeScroll = NSScrollView()
        treeScroll.drawsBackground = false
        treeScroll.hasVerticalScroller = true
        treeScroll.verticalScroller = SlimScroller()
        treeScroll.scrollerStyle = .overlay
        treeScroll.autohidesScrollers = true
        treeScroll.documentView = outline
        treeScroll.automaticallyAdjustsContentInsets = false
        treeScroll.contentInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        treeScroll.translatesAutoresizingMaskIntoConstraints = false

        treeRule.wantsLayer = true
        treeRule.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        treeRule.translatesAutoresizingMaskIntoConstraints = false

        diffTable.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = Theme.current.chrome.muted.nsColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isHidden = true

        let diffHost = NSView()
        diffHost.translatesAutoresizingMaskIntoConstraints = false
        diffHost.addSubview(diffTable)
        diffHost.addSubview(messageLabel)

        let footer = buildFooter()

        card.addSubview(treeScroll)
        card.addSubview(treeRule)
        card.addSubview(diffHost)
        card.addSubview(footerDivider)
        card.addSubview(footer)

        NSLayoutConstraint.activate([
            footerDivider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),

            treeScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            treeScroll.topAnchor.constraint(equalTo: card.topAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            treeScroll.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.3),

            treeRule.leadingAnchor.constraint(equalTo: treeScroll.trailingAnchor),
            treeRule.topAnchor.constraint(equalTo: card.topAnchor),
            treeRule.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            treeRule.widthAnchor.constraint(equalToConstant: 1),

            diffHost.leadingAnchor.constraint(equalTo: treeRule.trailingAnchor),
            diffHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            diffHost.topAnchor.constraint(equalTo: card.topAnchor),
            diffHost.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            diffTable.leadingAnchor.constraint(equalTo: diffHost.leadingAnchor),
            diffTable.trailingAnchor.constraint(equalTo: diffHost.trailingAnchor),
            diffTable.topAnchor.constraint(equalTo: diffHost.topAnchor),
            diffTable.bottomAnchor.constraint(equalTo: diffHost.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: diffHost.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: diffHost.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: diffHost.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: diffHost.trailingAnchor, constant: -24),
        ])
    }

    private func buildFooter() -> NSView {
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false

        hintsLabel.font = .systemFont(ofSize: 11)
        hintsLabel.alignment = .right
        hintsLabel.attributedStringValue = Self.hintsText()
        hintsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintsLabel.setContentHuggingPriority(.required, for: .horizontal)
        hintsLabel.translatesAutoresizingMaskIntoConstraints = false

        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statsLabel)
        footer.addSubview(hintsLabel)
        NSLayoutConstraint.activate([
            statsLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            statsLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintsLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            hintsLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statsLabel.trailingAnchor, constant: 12),
        ])
        return footer
    }

    // MARK: loading

    private func reload(showSpinner: Bool) {
        loadToken += 1
        let token = loadToken
        if showSpinner { showMessage("Loading…") }
        loader { [weak self] result in
            guard let self, token == self.loadToken else { return }
            switch result {
            case .success(let status):
                guard status != self.displayedStatus else { return }  // unchanged — keep the view
                self.apply(status)
            case .failure(let failure):
                self.displayedStatus = nil
                self.statsLabel.stringValue = ""
                self.showMessage(self.failureMessage(for: failure))
            }
        }
    }

    private func apply(_ status: GitDiffRunner.StatusLoad) {
        displayedStatus = status
        statsLabel.attributedStringValue = Self.statsText(for: status)

        let controller = DiffTreeOutlineController(sections: DiffOutlineItem.sections(from: status)) {
            [weak self] file in self?.selectFile(file)
        }
        outlineController = controller
        outline.dataSource = controller
        outline.delegate = controller
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)

        selectedFilePath = nil
        guard let first = controller.firstFile, let file = first.fileDiff else {
            showMessage("No changes")
            return
        }
        let row = outline.row(forItem: first)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        selectFile(file)
    }

    private func selectFile(_ file: FileDiff) {
        // Dedup: the load both selects the row (firing this via the delegate) and calls here directly,
        // and re-selecting the shown file shouldn't re-render.
        guard selectedFilePath != file.path else { return }
        selectedFilePath = file.path
        messageLabel.isHidden = true
        diffTable.isHidden = false
        diffTable.show(SideBySideDiff.rows(for: file))
    }

    private func showMessage(_ text: String) {
        selectedFilePath = nil
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        diffTable.isHidden = true
    }

    private func failureMessage(for failure: GitDiffRunner.Failure) -> String {
        switch failure {
        case .gitUnavailable: return "git isn't available"
        case .gitError(let message): return message.isEmpty ? "Couldn't read the diff" : message
        }
    }

    private static func statsText(for status: GitDiffRunner.StatusLoad) -> NSAttributedString {
        let files = status.unstaged + status.staged + status.committed
        let added = files.reduce(0) { $0 + $1.addedCount }
        let removed = files.reduce(0) { $0 + $1.removedCount }
        let chrome = Theme.current.chrome
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: chrome.positive.nsColor]))
        text.append(NSAttributedString(string: "  "))
        text.append(
            NSAttributedString(string: "−\(removed)", attributes: [.foregroundColor: chrome.destructive.nsColor]))
        return text
    }

    private static func hintsText() -> NSAttributedString {
        // Glyphs come from the live keymap, so the hints show the user's own bindings, not the defaults.
        func glyph(_ chord: KeyInterceptor.ReservedChord) -> String { CommandCatalog.spec(for: chord).shortcut }
        let text =
            "\(glyph(.navLeft)) \(glyph(.navRight)) panes   "
            + "\(glyph(.navDown)) \(glyph(.navUp)) jump   ←/→ fold   esc close"
        return NSAttributedString(
            string: text, attributes: [.foregroundColor: Theme.current.chrome.ink(alpha: 0.45)])
    }

    // MARK: test hooks

    /// The number of rows the file tree currently shows (sections + expanded files).
    var treeRowCountForTesting: Int { outline.numberOfRows }
    /// The path of the file whose diff is in the right pane, or nil when a message is shown.
    var selectedFilePathForTesting: String? { selectedFilePath }
    /// The number of visual diff rows rendered in the right pane.
    var diffRowCountForTesting: Int { diffTable.rowCountForTesting }
    /// Drive a tree selection the way a click/arrow would, so a test exercises the real selection path.
    func selectRowForTesting(_ row: Int) {
        outline.selectRowIndexes([row], byExtendingSelection: false)
    }
}

/// The file tree's outline view. Accepts first responder even when empty (so keystrokes never leak to
/// the terminal behind the card). Navigation is driven by forwarded pane chords, not Tab; the only
/// key it claims is Esc, so it closes the viewer instead of the outline eating it as a deselect.
private final class NavOutlineView: NSOutlineView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .escape:
            onEscape?()
            return
        case .activate:
            // Return/Enter on a folder or section folds it, matching Left/Right — a file just stays
            // selected (its diff is already shown).
            if let item = item(atRow: selectedRow), isExpandable(item) {
                if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}
