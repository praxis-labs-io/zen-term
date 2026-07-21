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
    /// Loads the repo status for a chosen base (nil = the repo's default) and calls back on the main
    /// thread. Injected so the overlay never touches `Process` itself; `WindowController` wires this to
    /// a `GitDiffRunner`.
    typealias Loader = (String?, @escaping (StatusResult) -> Void) -> Void
    /// Loads the repo's branches (base-picker order) and calls back on the main thread.
    typealias BranchesLoader = (@escaping ([String]) -> Void) -> Void

    private let loader: Loader
    private let branchesLoader: BranchesLoader
    private let onCancel: () -> Void

    /// The base the committed slice is compared against once the user overrides the default via the
    /// base picker; nil defers to the repo's default (main/master).
    private var baseOverride: String?
    /// The base picker while it's hosted over this card, so nav chords/Esc route to it and a second
    /// open is idempotent.
    private var basePicker: DiffBasePickerOverlay?
    /// The repo's branches, loaded in the background and refreshed on each status load, so the base
    /// picker opens instantly (git branch listing is fast, but not click-latency fast).
    private var branches: [String] = []

    private let card = CardView()
    private var dismiss = DismissGate()

    private let outline = NavOutlineView()
    private var outlineController: DiffTreeOutlineController?
    private let treeRule = NSView()
    private let diffTable = DiffPaneTable()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let footerDivider = NSView()
    private let statsLabel = NSTextField(labelWithString: "")
    private let hintsStack = NSStackView()

    private var selectedFilePath: String?
    /// The status currently on screen — a background refresh that returns the same thing is a no-op,
    /// so a reopen from the same dir doesn't yank the view (or flash) when nothing has changed.
    private var displayedStatus: GitDiffRunner.StatusLoad?
    /// Guards against a slower older load overwriting a newer one.
    private var loadToken = 0

    init(
        background: NSColor, initialStatus: GitDiffRunner.StatusLoad?, loader: @escaping Loader,
        branchesLoader: @escaping BranchesLoader, onCancel: @escaping () -> Void
    ) {
        self.loader = loader
        self.branchesLoader = branchesLoader
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onCancel)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background, halo: true)
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
        refreshBranches()
    }

    /// Pull the repo's branches into the cache so the base picker opens without a load delay. Cheap
    /// (a local `for-each-ref`); refreshed on each status load so a newly-created branch appears.
    private func refreshBranches() {
        branchesLoader { [weak self] branches in self?.branches = branches }
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
        // While the base picker is up it owns Esc (to close itself, not the whole viewer), so defer to
        // the responder traversal that reaches it instead of claiming Esc here.
        if basePicker != nil { return super.performKeyEquivalent(with: event) }
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card, halo: true)
        treeRule.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        footerDivider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        messageLabel.textColor = Theme.current.chrome.muted.nsColor
        fillHints()
        if let status = displayedStatus { statsLabel.attributedStringValue = Self.statsText(for: status) }
        outline.reloadData()
        diffTable.reapplyTheme()
        basePicker?.reapplyTheme()
    }

    // MARK: pane-chord navigation

    /// The pane-nav chords, forwarded by `WindowController` while this overlay is open (KeyInterceptor
    /// consumes chords before the responder chain, so the overlay can't see them itself). ⌘h/⌘l move
    /// between the tree and the diff; ⌘j/⌘k jump to the next/previous change in the focused pane.
    /// Returns true when it consumed the chord.
    func handleNavChord(_ chord: KeyInterceptor.ReservedChord) -> Bool {
        // The base picker owns navigation while it's up (its own list handles the arrows); swallow the
        // pane chords so they don't drive the tree behind it.
        if basePicker != nil { return true }
        switch chord {
        case .navLeft:
            window?.makeFirstResponder(outline)
            refreshFocusStyling()
        case .navRight:
            window?.makeFirstResponder(diffTable.scrollFocusTarget)
            refreshFocusStyling()
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

    /// Redraw both panes' selection when focus moves between them: the tree's selected file switches
    /// between a solid fill (focused) and a quiet outline (not), and the diff's cursor line only
    /// shows while the diff is focused. AppKit's `isEmphasized` redraw across two views in one window
    /// isn't reliable, so nudge it.
    private func refreshFocusStyling() {
        outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        diffTable.redrawSelection()
    }

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

    // MARK: base picker

    /// Open the base picker over the card (hosted here, not the window's modal slot, so dismissing it
    /// returns to the diff). Idempotent; uses the cached branch list so it appears without a delay.
    private func openBasePicker() {
        guard basePicker == nil else { return }
        let picker = DiffBasePickerOverlay(
            branches: branches,
            currentBase: displayedStatus?.baseBranch,
            background: Theme.current.chrome.background.nsColor,
            onChoose: { [weak self] branch in self?.chooseBase(branch) },
            onDismiss: { [weak self] in self?.dismissBasePicker() })
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        basePicker = picker
        layoutSubtreeIfNeeded()
        picker.focusInitialResponder()
        picker.animateIn()
    }

    /// Compare against the chosen branch: re-run the committed slice against it, keeping the current
    /// diff on screen until the new one lands (no spinner flash). A reselect of the current base is a
    /// no-op.
    private func chooseBase(_ branch: String) {
        dismissBasePicker()
        guard branch != displayedStatus?.baseBranch else { return }
        baseOverride = branch
        reload(showSpinner: false)
    }

    private func dismissBasePicker() {
        guard let picker = basePicker else { return }
        basePicker = nil
        picker.animateOut { picker.removeFromSuperview() }
        window?.makeFirstResponder(outline)
        refreshFocusStyling()
    }

    // MARK: layout

    private func buildLayout() {
        // Two columns: the name (indented outline column, flexible) and the +n −m stat (fixed width,
        // right-aligned) so stats align on a common right edge and never clip on a nested file.
        let nameColumn = NSTableColumn(identifier: DiffTreeOutlineController.nameColumnID)
        nameColumn.resizingMask = .autoresizingMask
        let statColumn = NSTableColumn(identifier: DiffTreeOutlineController.statColumnID)
        statColumn.width = 78
        statColumn.minWidth = 78
        statColumn.maxWidth = 78
        statColumn.resizingMask = []
        outline.addTableColumn(nameColumn)
        outline.addTableColumn(statColumn)
        outline.outlineTableColumn = nameColumn
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
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

        hintsStack.orientation = .horizontal
        hintsStack.spacing = 16
        hintsStack.alignment = .centerY
        hintsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintsStack.setContentHuggingPriority(.required, for: .horizontal)
        hintsStack.translatesAutoresizingMaskIntoConstraints = false
        fillHints()

        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statsLabel)
        footer.addSubview(hintsStack)
        NSLayoutConstraint.activate([
            statsLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            statsLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintsStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            hintsStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintsStack.leadingAnchor.constraint(greaterThanOrEqualTo: statsLabel.trailingAnchor, constant: 12),
        ])
        return footer
    }

    /// The footer's key legend as real keycaps, built from the live keymap so it shows the user's own
    /// pane/jump bindings (not the defaults). Rebuilt in full on a theme/keymap change — every keycap
    /// bakes its colors in at construction, so it's re-created rather than mutated.
    private func fillHints() {
        hintsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func glyph(_ chord: KeyInterceptor.ReservedChord) -> String { CommandCatalog.spec(for: chord).shortcut }
        let groups: [(keys: String, label: String)] = [
            ("\(glyph(.navLeft)) \(glyph(.navRight))", "panes"),
            ("\(glyph(.navDown)) \(glyph(.navUp))", "jump"),
            ("←/→", "fold"),
            ("esc", "close"),
        ]
        for group in groups { hintsStack.addArrangedSubview(Self.hintGroup(keys: group.keys, label: group.label)) }
    }

    /// One `[keycap]  label` pair for the footer legend: a themed keycap next to a muted caption.
    private static func hintGroup(keys: String, label: String) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = Theme.current.chrome.ink(alpha: 0.45)
        let stack = NSStackView(views: [KeycapView(shortcut: keys), caption])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    // MARK: loading

    private func reload(showSpinner: Bool) {
        loadToken += 1
        let token = loadToken
        if showSpinner { showMessage("Loading…") }
        loader(baseOverride) { [weak self] result in
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
        refreshBranches()  // keep the picker's list fresh across refreshes
        statsLabel.attributedStringValue = Self.statsText(for: status)

        let controller = DiffTreeOutlineController(
            sections: DiffOutlineItem.sections(from: status),
            onSelect: { [weak self] file in self?.selectFile(file) },
            onPickBase: { [weak self] in self?.openBasePicker() })
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let text = NSMutableAttributedString()
        text.append(
            NSAttributedString(
                string: "+\(added)", attributes: [.foregroundColor: chrome.positive.nsColor, .font: font]))
        text.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        text.append(
            NSAttributedString(
                string: "−\(removed)", attributes: [.foregroundColor: chrome.destructive.nsColor, .font: font]))
        return text
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
    /// Open the base picker the way the Committed header's base button does (the button itself, buried
    /// in an outline row, is a runbook check), so a test can drive the picker → base-override wiring.
    func openBasePickerForTesting() { openBasePicker() }
    /// The hosted base picker, or nil when it's closed.
    var basePickerForTesting: DiffBasePickerOverlay? { basePicker }
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
