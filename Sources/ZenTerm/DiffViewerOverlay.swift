import AppKit

/// The diff viewer: a chrome-native modal card over the active tile. The left column is a single file
/// tree split into three sections — Unstaged, Staged, Committed (top to bottom) — the right column is
/// the diff of the selected file, and a full-width footer carries the repo name + branch and the key hints. A
/// `ModalOverlay` sharing the card + backdrop + spring and Esc model with the other overlays. Git work
/// is injected as `loader`; the caller only opens this over a real repo (a non-repo shows a toast), so
/// there is no not-a-repo state.
///
/// Navigation is vim-native and local to this view (ZEN-262). ⌘h/⌘l move focus between the tree and
/// the diff — the app's pane chords, forwarded through `handleNavChord` since KeyInterceptor consumes
/// chords before the responder chain — and everything else is a bare key the panes handle in `keyDown`.
/// In the tree: j/k step files, h/l (and ←/→) fold or open a file into the diff, b focuses the base. In
/// the diff: j/k move the cursor, {/} jump changes, V selects, y/Y yank, ⏎ comments, h returns to the
/// tree. `\` toggles the layout and q/esc close, from either pane.
///
/// The diff renders in one of two layouts (ZEN-228): `SideBySideDiff` (old │ new) or `UnifiedDiff`
/// (inline), toggled by bare `\`. Both transforms feed the same `DiffPaneTable` behind the
/// layout-agnostic `DiffRow` model; the effective layout is the session override (`layoutOverride`),
/// else the `diff-layout` config default.
final class DiffViewerOverlay: NSView, ModalOverlay {
    typealias StatusResult = Result<GitDiffRunner.StatusLoad, GitDiffRunner.Failure>
    /// Loads the repo status for a chosen base (nil = the repo's default) and a chosen head (nil = the
    /// checkout's own `HEAD`) and calls back on the main thread. Injected so the overlay never touches
    /// `Process` itself; `WindowController` wires this to a `GitDiffRunner`.
    ///
    /// The head is passed as the whole `BranchOption` rather than a name because picking a branch that
    /// has a worktree means reading a *different directory*, which needs a different runner. Only the
    /// host can build that, so the overlay hands over the choice and stays out of it (ZEN-313).
    typealias Loader = (String?, GitDiffRunner.BranchOption?, @escaping (StatusResult) -> Void) -> Void
    /// Loads the repo's branches (base-picker order) and calls back on the main thread.
    typealias BranchesLoader = (@escaping ([String]) -> Void) -> Void
    /// Loads the branches the viewer can be pointed at, checked-out first, each tagged with its
    /// worktree. Separate from `BranchesLoader` because the base picker hides the current branch and
    /// the head picker leads with it.
    typealias HeadsLoader = (@escaping ([GitDiffRunner.BranchOption]) -> Void) -> Void
    /// The terminals in the active tab a comment can go to, **focused one first** — the composer
    /// defaults to index 0, so a send with no dropdown interaction lands where you were working.
    typealias SendTargets = () -> [DiffSendTarget]
    /// Deliver a composed comment to `target`: `submit` (⏎) pastes and presses Return and the host
    /// closes the viewer; `queue` (⌘⏎) pastes a line to stack for later and leaves the viewer open.
    typealias Sender = (_ message: String, _ target: DiffSendTarget, _ action: DiffSendAction) -> Void

    private let loader: Loader
    private let branchesLoader: BranchesLoader
    private let headsLoader: HeadsLoader
    private let sendTargets: SendTargets
    private let sender: Sender
    private let onCancel: () -> Void
    private let onRepoRootChange: (URL) -> Void

    /// The base the committed slice is compared against once the user overrides the default via the
    /// base dropdown; nil defers to the repo's default (main/master).
    private var baseOverride: String?
    /// The repo's branches, loaded in the background and refreshed on each status load, so the base
    /// dropdown is populated (git branch listing is fast, but async).
    private var branches: [String] = []

    /// The branch the viewer is showing once the reader picks one, nil for the checkout's own head.
    /// A branch with a worktree reads that worktree (all three slices live); one without shows only
    /// the committed slice, because there is no working tree to read (ZEN-313).
    private var headOverride: GitDiffRunner.BranchOption?
    /// The branches offerable as heads, loaded alongside `branches`.
    private var heads: [GitDiffRunner.BranchOption] = []

    private let card = CardView()
    private var dismiss = DismissGate()

    /// The static header above the tree: the branch dropdown, its trigger reading `Base: <branch>`.
    /// Shown only when the committed slice has a resolved base; hidden (zero height) otherwise, so a
    /// repo with no commits vs. its base shows just the tree.
    private let baseHeader = NSView()
    private var baseDropdown: Dropdown!  // created in buildLayout (its onChange needs self)
    private var headDropdown: Dropdown!  // ditto — reads `Branch: <name>`
    private let pickerStack = NSStackView()
    private var baseHeaderHeight: NSLayoutConstraint!
    private var treeWidthProportional: NSLayoutConstraint!

    private let outline = NavOutlineView()
    private var outlineController: DiffTreeOutlineController?
    private let treeRule = NSView()
    private let diffTable = DiffPaneTable()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let footerDivider = NSView()
    /// The footer's leading identity: repo name, a branch glyph, and the checked-out branch. The branch
    /// glyph + name collapse when the repo is detached (no current branch).
    private let repoBranchStack = NSStackView()
    private let repoLabel = NSTextField(labelWithString: "")
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let hintsStack = NSStackView()
    /// The repo the viewer is showing, shown in the footer. The last path component of the repo root.
    private let repoName: String

    private var selectedFilePath: String?
    /// The repo root, for the syntax highlighter's blob fetch (ZEN-239).
    /// The root every git read resolves against: the worktree of the picked branch when it has one,
    /// else the repo the viewer opened on. A `var` because picking a worktree head retargets it, and
    /// the highlighter has to follow the loader (ZEN-313). It used to be frozen at init, so a picked
    /// worktree branch's diff was highlighted with the *checkout's* file contents.
    private var repoRoot: URL
    /// Discards a stale highlight result when the selection moved on before the off-main parse landed
    /// (fast file-switching) — mirrors `loadToken`.
    private var highlightToken = 0
    /// What this repo's viewer remembers between opens: the highlight cache, the last status, the picked
    /// base, and where the reader was. Read at init, written back when the card leaves the window.
    private let session: DiffViewerSession
    /// Per-repo highlight cache, shared with the `WindowController` so it survives a viewer close/reopen
    /// (a reopened repo paints highlighted immediately). Cleared on a changed reload (see `reload`).
    private let highlightStore: DiffHighlightStore
    /// The place a reopen has to land on, held until the first load has a tree to put it back into. Nil
    /// afterwards: every later load reads the place off the live view instead (ZEN-233).
    private var pendingPlace: DiffViewerPlace?
    /// A cursor line waiting for its file's rows to arrive, tagged with the path it belongs to — the
    /// highlight can land after the reader has moved on, and a cursor restored into the wrong file would
    /// jump them somewhere they never were.
    private var pendingCursor: (path: String, line: DiffSelection.LineNumbers)?
    /// Warms the highlight cache for the non-selected files in the background, so navigation lands on a
    /// warm cache instead of a fetch+parse wait. Rescheduled on every `apply`, cancelled on `deinit`.
    private var prefetcher: DiffFilePrefetcher
    /// The parsed diff currently shown, kept so a layout flip re-renders without a git re-run.
    private var currentFileDiff: FileDiff?
    /// The layout the shown rows were built with — a config-default change only re-renders when it
    /// actually differs, so a theme change alone doesn't reset the scroll or selection.
    private var renderedLayout: GeneralConfig.DiffLayout?
    /// A per-session layout override set by the bare `\` layout toggle while the pane is wide, never
    /// persisted; nil defers to the config default (`GeneralConfig.current.diffLayout`). Only governs the
    /// wide state — a narrow pane force-folds to inline regardless (ZEN-243).
    private var layoutOverride: GeneralConfig.DiffLayout?
    /// Whether the pane is currently narrow enough to force inline. A stored dead-band decision, not a
    /// pure function of the current width — it only flips true below `foldWidth` and back to false above
    /// `unfoldWidth`, so a width sitting between the two keeps whatever it last decided (no flapping).
    private var isNarrow = false

    /// The narrowest a side-by-side column may usefully get before folding to inline — set for the point
    /// two columns stop being worth the cramping (≈40 monospace chars per side at `DiffCellMetrics.font`),
    /// not the point they become literally unreadable. Runbook-tunable: raise it to fold at wider windows.
    private static let minSideBySideColumnWidth: CGFloat = 280
    /// The pane width at which a side-by-side column drops below `minSideBySideColumnWidth` — inverts the
    /// cell's own formula (two gutters + the 1pt center rule, split evenly). Uses the nominal (5-digit)
    /// gutter so the fold point stays stable across files rather than shifting with each file's own gutter.
    private static let foldWidth: CGFloat = 2 * DiffCellMetrics.nominalGutterWidth + 1 + 2 * minSideBySideColumnWidth
    /// `foldWidth` plus a dead-band the pane must clear before auto-unfolding back to side-by-side, so a
    /// resize sitting on the boundary can't flap the renderer tick to tick.
    private static let unfoldWidth: CGFloat = foldWidth + 60
    /// The status currently on screen — a background refresh that returns the same thing is a no-op,
    /// so a reopen from the same dir doesn't yank the view (or flash) when nothing has changed.
    private var displayedStatus: GitDiffRunner.StatusLoad?
    /// Guards against a slower older load overwriting a newer one.
    private var loadToken = 0
    /// Git status loads are deliberately single-flight. Filesystem events can keep arriving while a
    /// large diff is loading; one pending bit preserves the newest requested state without stacking
    /// subprocesses that can only be discarded when they finish.
    private var loadInFlight = false
    private var pendingReload = false
    private var pendingReloadShowsSpinner = false

    init(
        background: NSColor, session: DiffViewerSession,
        loader: @escaping Loader, branchesLoader: @escaping BranchesLoader,
        headsLoader: @escaping HeadsLoader,
        sendTargets: @escaping SendTargets, sender: @escaping Sender,
        onRepoRootChange: @escaping (URL) -> Void = { _ in },
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.repoName = session.repoRoot.lastPathComponent
        self.repoRoot = session.repoRoot
        self.highlightStore = session.highlights
        self.baseOverride = session.baseOverride
        self.pendingPlace = session.place
        self.prefetcher = DiffFilePrefetcher(repoRoot: session.repoRoot, highlightStore: session.highlights)
        self.loader = loader
        self.branchesLoader = branchesLoader
        self.headsLoader = headsLoader
        self.headOverride = session.headOverride
        self.sendTargets = sendTargets
        self.sender = sender
        self.onRepoRootChange = onRepoRootChange
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
        // show the spinner while the first load runs. A session carrying a picked base can't take the
        // warm path — the cached status is the *default* base's, so rendering it would show the wrong
        // comparison until the re-run lands.
        // `lastStatus` is the default base's, for the checkout's own head. Either override makes it the
        // wrong thing to paint, so a session carrying one loads instead of rendering from cache.
        if let cached = session.lastStatus, baseOverride == nil, headOverride == nil {
            apply(cached)
            reload(showSpinner: false)
        } else {
            reload(showSpinner: true)
        }
    }

    /// A fallback snapshot for a teardown that skips `animateOut` — the whole window closing (⌘W) pulls
    /// the card without a close spring. The normal close goes through `animateOut`, which snapshots
    /// earlier; `snapshotPlace` runs once, so whichever fires first wins (ZEN-233).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        snapshotPlace()
    }

    /// Write where the reader was (folds, open file, cursor line) and the picked base back into the
    /// session, so the next ⌘D on this repo opens where they left off. Once only: the earliest teardown
    /// signal takes it, and a later one must not clobber the session a fast-reopened overlay now shares.
    private var didSnapshotPlace = false
    private func snapshotPlace() {
        guard !didSnapshotPlace else { return }
        didSnapshotPlace = true
        session.place = currentPlace()
        session.baseOverride = baseOverride
        session.headOverride = headOverride
    }

    /// Pull the repo's branches so the base dropdown is populated. Cheap (a local `for-each-ref`);
    /// refreshed on each status load so a newly-created branch appears, then the dropdown rebuilds.
    private func refreshBranches() {
        branchesLoader { [weak self] branches in
            self?.branches = branches
            self?.updateBaseHeader()
        }
        headsLoader { [weak self] heads in
            guard let self else { return }
            self.heads = heads
            let hadOverride = self.headOverride != nil
            // A branch can vanish between refreshes (deleted, or its worktree moved), and a session
            // restores an override from a previous open. Re-resolve by name against what git just
            // reported: the picker would otherwise show one branch while `reload` asked the host for
            // another. Skipped on an empty list so a failed listing doesn't discard a live selection.
            if !heads.isEmpty {
                if let override = self.headOverride {
                    self.headOverride = heads.first { $0.name == override.name }
                }
                // Unconditional, because clearing an override needs the root moved back just as much as
                // setting one needs it moved. `retargetRepoRoot` is idempotent, so a no-change refresh
                // costs nothing.
                self.retargetRepoRoot()
            }
            self.updateBaseHeader()
            if hadOverride, self.headOverride == nil {
                // The status load that prompted this branch refresh still targeted the vanished
                // worktree and may already have failed. Reload on the next main turn, after that result
                // has settled, so the restored root repopulates the base picker, tree, and footer.
                DispatchQueue.main.async { [weak self] in
                    self?.reload(showSpinner: false)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        prefetcher.cancelAll()
    }

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
        // Snapshot the place here, at close-start: `closeModal` defers `removeFromSuperview` into the
        // spring's completion, so `viewDidMoveToWindow` alone would snapshot only at the animation's
        // end — after a fast reopen (⌘D toggles closed, ⌘D again) has already built the next overlay
        // and read the stale session. `animateOut` runs synchronously when the close begins.
        snapshotPlace()
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The composer is a child card, so while it's up it owns Esc (cancel the comment, not the
        // viewer), ⏎/⇧⏎ (send) and ⌘C (copy the note being typed). Offered first for exactly that
        // reason — otherwise this method's own Esc and yank would fire straight through it.
        if let composer, composer.handleKeyEquivalent(event) { return true }
        if composer != nil { return super.performKeyEquivalent(with: event) }
        // Esc closes the key sheet first if it's open, before it would close the viewer.
        if keySheet?.isShown == true, KeyboardFocus.key(for: event) == .escape {
            keySheet?.hide()
            return true
        }
        // A bare Esc reaches the focused control's keyDown first, so an open base dropdown closes its
        // own list there before this ever runs; here Esc closes the viewer.
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        // ⌘C / ⌘⇧C yank the diff selection. Claimed here because the view hierarchy is offered a key
        // equivalent before the main menu is — otherwise both would reach the menu's `copyFromSurface:`
        // and copy the *terminal's* selection while the viewer is up (ZEN-227).
        if let wantsReference = Self.yankShortcut(for: event) {
            yank(reference: wantsReference)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Toggle the bare `?` key-reference popover, anchored just above the footer's trailing edge.
    private func toggleKeySheet() {
        let sheet = keySheet ?? ChromePopover(makeContent: DiffKeymapSheet.makeContent)
        keySheet = sheet
        sheet.toggle(in: card, above: footerDivider)
    }

    // MARK: comment composer (ZEN-257)

    /// The open composer, or nil. Held so the viewer can route keys to it and so a second ⏎ can't
    /// stack two of them.
    private var composer: DiffCommentComposer?

    /// The bare `?` key-reference popover, created on first use. It floats above the footer's trailing edge
    /// and carries the full keymap the lean footer legend doesn't (ZEN-262).
    private var keySheet: ChromePopover?

    /// ⏎ on the diff pane: comment on the selected lines. With no visual selection running the
    /// selection is the cursor line, so there is always something to comment on — but a message state
    /// (no file) or a tab with no terminal to send to has nothing to say, and stays quiet.
    ///
    /// The box drops into the diff under the selection rather than over it, so the lines it's about
    /// stay on screen while you write about them (the pane pushes what's below them down).
    private func openComposer() {
        guard composer == nil, let file = currentFileDiff else { return }
        let selection = DiffSelection.make(rows: diffTable.rows, selected: diffTable.selectedRows)
        guard !selection.isEmpty else { return }
        let targets = sendTargets()
        guard !targets.isEmpty else { return }

        // Removed lines are in no file the agent can open, so a removals-only or deleted-file
        // selection carries them in the message instead of only pointing at them.
        let removedLines = selection.newRange == nil ? selection.lines : []
        let composer = DiffCommentComposer(
            reference: DiffReference.string(
                path: file.path, changeKind: file.changeKind, selection: selection),
            removedLines: removedLines,
            targets: targets,
            onSend: { [weak self] message, target, action in self?.send(message, to: target, action: action) },
            onCancel: { [weak self] in self?.closeComposer() })
        composer.onRequestHeight = { [weak self] height in self?.diffTable.setComposerHeight(height) }
        self.composer = composer
        // The box hangs under the *last* selected line so that line, and everything above it, stays
        // put — only what's below is pushed down (`selectedRows.max()`, not the table's reported
        // selectedRow, which is the anchor of an upward selection).
        let anchor = diffTable.selectedRows.max() ?? 0
        diffTable.showComposer(composer, below: anchor, height: DiffCommentComposer.height)
        composer.focusInitialResponder()
    }

    /// Close the box and hand focus back to the diff, with the selection it was about still standing —
    /// cancelling a comment shouldn't cost you the block you'd lined up.
    private func closeComposer() {
        guard composer != nil else { return }
        composer = nil
        diffTable.hideComposer()
        window?.makeFirstResponder(diffTable.scrollFocusTarget)
        refreshFocusStyling()
    }

    private func send(_ message: String, to target: DiffSendTarget, action: DiffSendAction) {
        // Close the box either way; the viewer itself only closes on submit (the host decides that
        // from the action), so a queue leaves you in the diff to line up the next comment.
        closeComposer()
        sender(message, target, action)
    }

    /// ⌘C (code) / ⌘⇧C (reference), or nil for anything else. Compares against the reservable set so
    /// the `.function` bit AppKit stamps on can't stop ⌘C matching a bare Command (ZEN-145).
    static func yankShortcut(for event: NSEvent) -> Bool? {
        guard event.charactersIgnoringModifiers?.lowercased() == "c" else { return nil }
        switch event.modifierFlags.intersection(DiffPaneTable.reservableModifiers) {
        case .command: return false
        case [.command, .shift]: return true
        default: return nil
        }
    }

    /// Where a yank lands. The system pasteboard in the app; a test points it at its own board so
    /// running the suite never clobbers what the developer had copied.
    var yankPasteboard: NSPasteboard = .general

    /// Copy the diff selection: the reference (`path:42-44`) or the selected code text. A yank with
    /// nothing selected, or on a message state with no file, is a no-op rather than an empty clipboard.
    private func yank(reference: Bool) {
        guard let file = currentFileDiff else { return }
        let selection = DiffSelection.make(rows: diffTable.rows, selected: diffTable.selectedRows)
        guard !selection.isEmpty else { return }
        let text =
            reference
            ? DiffReference.string(path: file.path, changeKind: file.changeKind, selection: selection)
            : selection.codeText
        yankPasteboard.clearContents()
        yankPasteboard.setString(text, forType: .string)
        // Confirm it after the write, not on the keystroke: a yank leaves nothing on screen, so a copy
        // that didn't take would otherwise look exactly like one that did.
        diffTable.flashYank()
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card, halo: true)
        treeRule.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        footerDivider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        baseDropdown.reapplyTheme()
        keySheet?.reapplyTheme()
        messageLabel.textColor = Theme.current.chrome.muted.nsColor
        fillHints()
        updateRepoBranch()
        outline.reloadData()
        // A config change can also change the default diff layout — re-render only if the effective
        // layout actually differs from what's shown. Otherwise just recolor, so a plain theme change
        // never resets the diff's scroll or selection.
        if !reconcileLayout() {
            diffTable.reapplyTheme()
        }
    }

    // MARK: pane-chord navigation

    /// The pane-nav chords, forwarded by `WindowController` while this overlay is open (KeyInterceptor
    /// consumes chords before the responder chain, so the overlay can't see them itself). ⌘h/⌘l move
    /// focus between the tree and the diff (left/right); ⌘j/⌘k (up/down) have nothing stacked to focus,
    /// so they fall through as no-ops. Everything else the viewer does — jump changes, fold, layout,
    /// base, yank, close — is a bare key the panes handle in `keyDown`. Returns true when it consumed
    /// the chord.
    func handleNavChord(_ chord: KeyInterceptor.ReservedChord) -> Bool {
        // Consumed, not acted on, while the composer is up: moving the pane focus underneath an open
        // comment would leave it pointing at lines you can no longer see.
        guard composer == nil else { return true }
        switch chord {
        case .navLeft: focusTree()
        case .navRight: focusDiff()
        default: return false
        }
        return true
    }

    /// Hand focus to the file tree (⌘h, or bare `h` from the diff pane). Inert while the composer is up:
    /// its controls sit under the diff table in the responder chain, so a bare key that bubbles up from a
    /// focused Submit/Queue button must not move focus out from under an open note (see `guardComposer`).
    private func focusTree() {
        guard guardComposer() else { return }
        window?.makeFirstResponder(outline)
        refreshFocusStyling()
    }

    /// Hand focus to the diff (⌘l, or bare `l` on a file in the tree).
    private func focusDiff() {
        guard guardComposer() else { return }
        window?.makeFirstResponder(diffTable.scrollFocusTarget)
        refreshFocusStyling()
    }

    /// The viewer's bare keys (`\` `b` `q` `h`) are decoded in the panes' `keyDown`, and the comment
    /// composer's box is a subview of the diff table — so a bare key pressed while a composer button holds
    /// focus bubbles up the responder chain into the diff table and would fire the viewer command. Gate
    /// every viewer command on this so a stray key can't re-render, refocus, or close the viewer out from
    /// under an open note (the same protection `handleNavChord` gives the ⌘-chords). Returns true when it's
    /// safe to act.
    private func guardComposer() -> Bool { composer == nil }

    /// Resync everything that keys off which pane holds focus: the tree's selected file switches between
    /// a solid fill (focused) and a quiet outline (not), the diff's cursor line only shows while the diff
    /// is focused, and the footer legend scopes to the focused pane. AppKit's `isEmphasized` redraw
    /// across two views in one window isn't reliable, so nudge it. Called on every tree↔diff focus move —
    /// the keyboard paths (⌘h/⌘l, bare h/l), and via each pane's `becomeFirstResponder` a mouse click.
    private func refreshFocusStyling() {
        outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        diffTable.redrawSelection()
        fillHints()
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

    /// Ctrl-j/k / Ctrl-↑↓ in the tree: jump the file selection about half a visible page and center it,
    /// the tree's echo of the diff's soft half-page. Steps file-by-file (so it lands on a real file, not a
    /// header or directory) `page` times, then centers the row — a long changed-file list moves without a
    /// key-repeat, staying near the middle of the pane the way the diff cursor does.
    private func pageFileSelection(_ direction: Int) {
        // Count the rows actually on screen rather than dividing the clip height by a row height: the tree
        // mixes 34pt section headers with 20pt file rows, so any single sampled height mis-sizes the page
        // (row 0 is always a section header). Half the visible rows is a page; step that many files.
        let page = max(1, outline.rows(in: outline.visibleRect).length / 2)
        for _ in 0..<page { moveFileSelection(direction) }
        centerSelectedTreeRow()
    }

    /// Scroll the selected tree row to the vertical center of the clip (clamped to the document), so
    /// paging leaves the file near the middle instead of flush against an edge.
    private func centerSelectedTreeRow() {
        let row = outline.selectedRow
        guard row >= 0, let clip = outline.enclosingScrollView?.contentView else { return }
        let rowRect = outline.rect(ofRow: row)
        let maxY = max(0, outline.bounds.height - clip.bounds.height)
        let target = min(max(0, rowRect.midY - clip.bounds.height / 2), maxY)
        outline.scroll(NSPoint(x: 0, y: target))
    }

    // MARK: base dropdown

    /// The branch order backing the dropdown (the loaded branches, with the current base guaranteed
    /// present), so `onChange`'s index maps back to a branch name.
    private var baseItems: [String] = []

    /// Rebuild the base dropdown from the current status + loaded branches, and show or hide the header
    /// with it: shown whenever a base resolved (so the base is always changeable), hidden when there's
    /// none (a repo with no base). Called on each load and whenever the branch list refreshes.
    private func updateBaseHeader() {
        // A branch is never comparable to itself, so each picker hides the other's selection. Both
        // exclusions live here because only this layer knows both, and both move as the reader picks.
        // Each keeps its *own* selection regardless, or picking would remove the thing you just picked.
        let currentBase = displayedStatus?.baseBranch
        let currentHead = headOverride?.name ?? heads.first(where: \.isCurrent)?.name

        updateHeadDropdown(excludingBase: currentBase, selected: currentHead)

        if let currentBase {
            var items = branches.filter { $0 == currentBase || $0 != currentHead }
            if !items.contains(currentBase) { items.insert(currentBase, at: 0) }  // an override off the list
            baseItems = items
            let selected = items.firstIndex(of: currentBase) ?? 0
            baseDropdown.setItems(
                items.map { DropdownItem(title: $0, group: nil, note: nil, isSelected: $0 == currentBase) },
                selectedIndex: selected)
        }
        // The base picker hides with no resolved base, but the branch picker does not: "there is nothing
        // to compare against" and "there is nothing to look at" are different, and the second is the
        // state a reader most needs a way out of (ZEN-313). So the header stays for either one.
        // Both pickers hide independently, and the stack collapses whichever is hidden. The head one
        // is empty on every open until `headsLoader` returns, so leaving it visible-but-blank showed an
        // untitled control and sized the header for a row nothing was in.
        headDropdown.isHidden = headItems.isEmpty
        baseDropdown.isHidden = currentBase == nil
        let shown = [headItems.isEmpty ? nil : headDropdown, currentBase == nil ? nil : baseDropdown]
            .compactMap { $0 }
        baseHeader.isHidden = shown.isEmpty
        baseHeaderHeight.constant = Self.headerHeight(forPickers: shown.count)
    }

    /// The branch order backing the head dropdown, so `onChange`'s index maps back to a branch.
    private var headItems: [GitDiffRunner.BranchOption] = []

    /// Rebuild the head dropdown. A branch with no worktree is noted as committed-only, because that
    /// is the difference the reader will otherwise discover as "my uncommitted work vanished".
    private func updateHeadDropdown(excludingBase base: String?, selected currentName: String?) {
        headItems = heads.filter { $0.name == currentName || $0.name != base }
        guard !headItems.isEmpty else {
            headDropdown.setItems([], selectedIndex: 0)
            return
        }
        let selected = headItems.firstIndex { $0.name == currentName } ?? 0
        headDropdown.setItems(
            headItems.map {
                DropdownItem(
                    title: $0.name, group: nil, note: $0.hasWorktree ? nil : "committed only",
                    isSelected: $0.name == currentName)
            },
            selectedIndex: selected)
    }

    /// Point the viewer at the chosen branch. Reselecting the one already shown is a no-op; picking the
    /// checked-out branch clears the override rather than pinning it, so the viewer goes back to plain
    /// "this checkout" and follows it if the reader switches branches underneath.
    private func chooseHeadAt(_ index: Int) {
        guard headItems.indices.contains(index) else { return }
        let picked = headItems[index]
        let shownName = headOverride?.name ?? heads.first(where: \.isCurrent)?.name
        guard picked.name != shownName else { return }
        headOverride = picked.isCurrent ? nil : picked
        retargetRepoRoot()
        // Rebuild both pickers now rather than waiting for the load. What each one offers depends on
        // the *selection*, and a reload that lands an identical status is a deliberate no-op (ZEN-233),
        // so leaving it to `apply` strands them showing the old pair whenever two branches happen to
        // produce the same diff.
        updateBaseHeader()
        reload(showSpinner: false)
    }

    /// Compare the committed slice against the chosen branch: re-run against it, keeping the current
    /// diff on screen until the new one lands (no spinner flash). Reselecting the current base is a
    /// no-op.
    private func chooseBaseAt(_ index: Int) {
        guard baseItems.indices.contains(index) else { return }
        let branch = baseItems[index]
        guard branch != displayedStatus?.baseBranch else { return }
        baseOverride = branch
        reload(showSpinner: false)
    }

    /// Move focus from the base dropdown down into the tree (Down from the closed dropdown), and back
    /// up from the top of the tree (Up at the first row) — so the dropdown is reachable by the arrows.
    private func focusTreeTop() {
        window?.makeFirstResponder(outline)
        if outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
        refreshFocusStyling()
    }

    /// Point every git read at the picked branch's worktree, or back at the repo the viewer opened on.
    ///
    /// The loader already does this for the *diff* by building a runner rooted at the worktree. The
    /// highlighter reads whole-file blobs separately (`DiffHighlighter.enrich`, and the prefetcher's
    /// background pass), and both took the root captured at init, so a picked worktree branch showed
    /// the right diff coloured by another branch's file contents. `FileDiff.headRef` covers only the
    /// no-worktree case: there the runner stays put and the *ref* moves, here the root itself moves.
    ///
    /// The highlight cache is keyed per file with no notion of which root produced it, so spans from
    /// the old root have to go rather than be reused under the same key. That also clears the poisoned
    /// nil a file added on the picked branch would otherwise cache forever.
    private func retargetRepoRoot() {
        let target = headOverride?.worktree ?? session.repoRoot
        guard target != repoRoot else { return }
        repoRoot = target
        prefetcher.cancelAll()
        prefetcher = DiffFilePrefetcher(repoRoot: target, highlightStore: highlightStore)
        highlightStore.clear()
        onRepoRootChange(target)
    }

    /// Step up out of the tree onto the nearest picker: the base one when it is showing, else the
    /// branch one. Without the fallback, a repo with no resolved base swallows Up at the top row, and
    /// the branch picker becomes mouse-only in exactly the case it matters most.
    private func focusHeaderFromTree() {
        if !baseDropdown.isHidden { focusBaseDropdown() } else { focusHeadDropdown() }
    }

    /// Step onto the branch picker. Inert when there are no branches to offer, so Tab off the base
    /// picker doesn't strand focus on a dropdown with an empty list.
    private func focusHeadDropdown() {
        guard guardComposer(), !baseHeader.isHidden, !headItems.isEmpty else { return }
        window?.makeFirstResponder(headDropdown)
    }

    private func focusBaseDropdown() {
        guard guardComposer(), !baseHeader.isHidden, !baseDropdown.isHidden else { return }
        // The base dropdown is a header control, not a pane, and it isn't reachable via the panes'
        // `becomeFirstResponder` hook — so it inherits whichever pane legend is up rather than flipping
        // it, keeping the keyboard (`b`) and the mouse (click) paths consistent.
        window?.makeFirstResponder(baseDropdown)
    }

    /// Close from a bare `q`. Inert while the composer is up: its own Esc/close cancels the note; a `q`
    /// bubbling up from a focused Submit/Queue button must not discard it by closing the whole viewer.
    private func requestClose() {
        guard guardComposer() else { return }
        onCancel()
    }

    /// Esc from a focused pane: close the key sheet first if it's up, else close the viewer. A bare Esc
    /// reaches the pane's `keyDown` before `performKeyEquivalent` (that's what makes the diff's two-stage
    /// Esc work), so the sheet check has to live on this path too, not only in `performKeyEquivalent`.
    private func handleViewerEscape() {
        if keySheet?.isShown == true {
            keySheet?.hide()
            return
        }
        onCancel()
    }

    // MARK: layout

    private func buildLayout() {
        // One flexible column: the indented name, filling the tree's full width. A file's change
        // magnitude reads from its status-tinted icon and the branch total sits in the footer, so no
        // row reserves width for a stat.
        let nameColumn = NSTableColumn(identifier: DiffTreeOutlineController.nameColumnID)
        // No legacy autoresizing mask / `.firstColumnOnlyAutoresizingStyle` here — that machinery
        // resizes the column by the DELTA between the outline's old and new width, not by filling
        // whatever's left. `reload()` populates the tree inside `init()`, before this view is ever
        // in a window, so the column's first "resize" event fires against a stale pre-Auto-Layout
        // width (NSTableColumn's 100pt default vs. the outline's placeholder frame) and never
        // recovers — `NavOutlineView.layout()` drives `nameColumn.width` explicitly instead (ZEN-226).
        nameColumn.resizingMask = []
        outline.addTableColumn(nameColumn)
        outline.outlineTableColumn = nameColumn
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.focusRingType = .none  // no system-blue ring on focus-in (ZEN-27: chrome is theme-only)
        // Force plain style: the default `.automatic` resolves to the inset/source-list family, whose
        // tiling reserves a constant +32pt in the outline's own frame *beyond* the column width (and
        // reports intercellSpacing as (17, 0), not the classic (3, 2)). That baked-in padding is what
        // made the document permanently wider than the clip regardless of content. `.plain` restores
        // the documented `documentWidth = columnWidth + intercellSpacing.width` relation, and zeroing
        // the width component makes `NavOutlineView.layout()`'s fill math exact (target == clip width).
        outline.style = .plain
        outline.intercellSpacing = NSSize(width: 0, height: outline.intercellSpacing.height)
        // The vim keys are plain letters, so AppKit's type-select would race j/k for every keystroke.
        outline.allowsTypeSelect = false
        outline.onEscape = { [weak self] in self?.handleViewerEscape() }
        outline.onFocusBase = { [weak self] in self?.focusHeaderFromTree() }
        outline.onHalfPageDiff = { [weak self] direction in self?.diffTable.halfPage(direction) }
        outline.onMoveFile = { [weak self] delta in self?.moveFileSelection(delta) }
        outline.onPageFiles = { [weak self] direction in self?.pageFileSelection(direction) }
        outline.onToggleLayout = { [weak self] in self?.toggleLayout() }
        outline.onFocusDiff = { [weak self] in self?.focusDiff() }
        outline.onClose = { [weak self] in self?.requestClose() }
        outline.onShowKeys = { [weak self] in self?.toggleKeySheet() }
        outline.onBecameFirstResponder = { [weak self] in self?.refreshFocusStyling() }
        diffTable.onEscape = { [weak self] in self?.handleViewerEscape() }
        diffTable.onYank = { [weak self] wantsReference in self?.yank(reference: wantsReference) }
        diffTable.onCompose = { [weak self] in self?.openComposer() }
        diffTable.onToggleLayout = { [weak self] in self?.toggleLayout() }
        diffTable.onFocusBase = { [weak self] in self?.focusHeaderFromTree() }
        diffTable.onFocusTree = { [weak self] in self?.focusTree() }
        diffTable.onClose = { [weak self] in self?.requestClose() }
        diffTable.onShowKeys = { [weak self] in self?.toggleKeySheet() }
        diffTable.onFocusChanged = { [weak self] in self?.refreshFocusStyling() }
        // Re-evaluate the auto-fold policy whenever the diff pane's width changes (ZEN-243). The frame
        // notification fires with the pane's *final* frame on every resize — reliable where piggybacking
        // on a `layout()` pass isn't (the inner table tiles after that runs, so it reads a stale width).
        diffTable.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(paneFrameDidChange), name: NSView.frameDidChangeNotification, object: diffTable)

        buildBaseHeader()

        let treeScroll = NSScrollView()
        // A single wide column can leave the outline's document a hair wider than the clip; lock the
        // clip's horizontal axis so the tree can never pan sideways (it only ever truncates names).
        let treeClip = LockedHorizontalClipView()
        treeClip.drawsBackground = false
        treeScroll.contentView = treeClip
        treeScroll.drawsBackground = false
        treeScroll.hasVerticalScroller = true
        treeScroll.verticalScroller = SlimScroller()
        treeScroll.scrollerStyle = .overlay
        treeScroll.autohidesScrollers = true
        treeScroll.documentView = outline
        treeScroll.automaticallyAdjustsContentInsets = false
        // Horizontal insets are 0 on purpose: NSScrollView `contentInsets` extend the clip's
        // *scrollable range*, not padding, so any left/right inset pans the tree sideways by that
        // amount (`LockedHorizontalClipView` then has nothing to fight). Vertical is a real scroll
        // axis, so its inset is fine. Left/right breathing room lives in the row content, not here.
        treeScroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        // The clip-lock pins the scroll *offset* at 0, but horizontal elasticity still lets a two-finger
        // swipe rubber-band the tree sideways past it. Kill the axis outright so the nav can only ever
        // truncate names, never pan.
        treeScroll.horizontalScrollElasticity = .none
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

        // The tree width is ~1/5 of the card, clamped to a min (never collapses) and a max (never
        // sprawls on a wide monitor). The proportional term is the load-bearing detail: a resizable
        // NSWindow treats its own frame as a layout variable at priority 500
        // (`NSLayoutPriorityWindowSizeStayPut`). This proportional *equality* traces to the window
        // through the overlay's edge pins, and on a wide display `0.2 × card` overshoots the 360 cap,
        // making the equality infeasible at the current size. Above priority 500, AppKit resolves that
        // by RESIZING THE WINDOW smaller (cheaper than leaving the equality in error) — the recurring
        // cross-feature shrink, and it only shows on a big monitor because that's the only place the
        // fraction crosses the cap. Kept below 500 (`.defaultLow`), the equality yields (the tree
        // clamps to 360) and the window is left alone. The min/max clamps are inequalities and don't
        // trip this, so their priority is free to stay above the proportional term so it wins.
        treeWidthProportional = treeScroll.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.2)
        treeWidthProportional.priority = NSLayoutConstraint.Priority(rawValue: 251)
        let treeMinWidth = treeScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        treeMinWidth.priority = .defaultHigh
        let treeMaxWidth = treeScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        treeMaxWidth.priority = .defaultHigh

        card.addSubview(baseHeader)
        card.addSubview(treeScroll)
        card.addSubview(treeRule)
        card.addSubview(diffHost)
        card.addSubview(footerDivider)
        card.addSubview(footer)

        baseHeaderHeight = baseHeader.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // The base dropdown header spans the tree column (left of the vertical rule), above the
            // tree. Its height toggles 0 ⇄ shown, so a repo with no base shows just the tree.
            baseHeader.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            baseHeader.trailingAnchor.constraint(equalTo: treeRule.leadingAnchor),
            baseHeader.topAnchor.constraint(equalTo: card.topAnchor),
            baseHeaderHeight,

            footerDivider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),

            treeScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            treeScroll.topAnchor.constraint(equalTo: baseHeader.bottomAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            treeWidthProportional, treeMinWidth, treeMaxWidth,

            treeRule.leadingAnchor.constraint(equalTo: treeScroll.trailingAnchor),
            treeRule.topAnchor.constraint(equalTo: card.topAnchor),
            treeRule.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            treeRule.widthAnchor.constraint(equalToConstant: 1),

            diffHost.leadingAnchor.constraint(equalTo: treeRule.trailingAnchor),
            diffHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            diffHost.topAnchor.constraint(equalTo: card.topAnchor),
            diffHost.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            // A small horizontal margin off the tree divider and the card edge, matching the current-line
            // pill's own inset so the content gap and the pill gap read as one consistent margin (the
            // `.plain` table style already removed the source-list inset that made it too wide).
            diffTable.leadingAnchor.constraint(equalTo: diffHost.leadingAnchor, constant: 6),
            diffTable.trailingAnchor.constraint(equalTo: diffHost.trailingAnchor, constant: -6),
            diffTable.topAnchor.constraint(equalTo: diffHost.topAnchor),
            diffTable.bottomAnchor.constraint(equalTo: diffHost.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: diffHost.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: diffHost.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: diffHost.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: diffHost.trailingAnchor, constant: -24),
        ])
    }

    /// One picker: 8pt above, the control, 8pt below.
    private static let baseHeaderShownHeight: CGFloat = 44
    private static let pickerRowHeight: CGFloat = baseHeaderShownHeight - 16  // the control alone
    private static let pickerRowGap: CGFloat = 6

    /// The header's height for however many pickers are showing. Derived rather than a constant per
    /// case, because either picker can be absent: a fixed pair-height stranded the base picker under
    /// the clip whenever the branch list hadn't loaded yet.
    static func headerHeight(forPickers count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = CGFloat(count) * pickerRowHeight
        let gaps = CGFloat(count - 1) * pickerRowGap
        return rows + gaps + 16  // 8pt above and below
    }

    /// The static header above the tree: just the branch dropdown, its trigger reading `Base: <branch>`
    /// (no separate caption, no bottom border — the padding alone separates it from the tree). The
    /// dropdown is the reused chrome `Dropdown` (anchored list, keyboard nav, checks), so this is not a
    /// modal; Down from the dropdown drops into the tree, Up from the tree's top row returns to it.
    private func buildBaseHeader() {
        baseHeader.translatesAutoresizingMaskIntoConstraints = false
        baseHeader.clipsToBounds = true  // stays tidy when collapsed to zero height

        headDropdown = Dropdown(items: [], selectedIndex: 0) { [weak self] index in self?.chooseHeadAt(index) }
        headDropdown.titlePrefix = "Branch: "
        // Stacked, so the arrows step vertically: Down off the branch picker lands on the base one
        // below it, and only falls through to the tree when there is no base to land on.
        headDropdown.onArrowDown = { [weak self] in
            guard let self else { return }
            if !baseDropdown.isHidden { focusBaseDropdown() } else { focusTreeTop() }
        }
        // The two pickers step between themselves with Tab, so the branch one is reachable without the
        // mouse. `b` still lands on the base picker, which is where it has always landed.
        headDropdown.onTab = { [weak self] in self?.focusBaseDropdown() }
        headDropdown.titleTruncatesUnderPressure = true

        baseDropdown = Dropdown(items: [], selectedIndex: 0) { [weak self] index in self?.chooseBaseAt(index) }
        baseDropdown.titlePrefix = "Base: "
        baseDropdown.onArrowDown = { [weak self] in self?.focusTreeTop() }
        baseDropdown.onArrowUp = { [weak self] in self?.focusHeadDropdown() }
        baseDropdown.onBacktab = { [weak self] in self?.focusHeadDropdown() }
        baseDropdown.titleTruncatesUnderPressure = true

        // Stacked, not side by side: both carry branch names, which are long and unbounded, so a row
        // split between them truncates two things at once and the card can't get narrow. Reading order
        // runs top to bottom, this branch then what it is measured against.
        //
        // An `NSStackView` rather than pinned constraints, because either picker can be absent and a
        // hidden view still participates in Auto Layout. Chaining `baseDropdown.top` off
        // `headDropdown.bottom` meant an empty branch list left the base picker pushed below a
        // one-row header that `clipsToBounds` then cut off. `detachesHiddenViews` (the default) drops
        // a hidden arranged subview out of the layout entirely, so the stack is however tall the
        // showing pickers need.
        pickerStack.orientation = .vertical
        pickerStack.alignment = .leading
        pickerStack.spacing = 6
        pickerStack.translatesAutoresizingMaskIntoConstraints = false
        pickerStack.setViews([headDropdown, baseDropdown], in: .leading)
        baseHeader.addSubview(pickerStack)
        NSLayoutConstraint.activate([
            pickerStack.leadingAnchor.constraint(equalTo: baseHeader.leadingAnchor, constant: 10),
            pickerStack.trailingAnchor.constraint(equalTo: baseHeader.trailingAnchor, constant: -10),
            pickerStack.topAnchor.constraint(equalTo: baseHeader.topAnchor, constant: 8),
            // Both pickers span the stack, so each truncates at the column's width rather than its own.
            headDropdown.widthAnchor.constraint(equalTo: pickerStack.widthAnchor),
            baseDropdown.widthAnchor.constraint(equalTo: pickerStack.widthAnchor),
        ])
    }

    private func buildFooter() -> NSView {
        repoLabel.font = .systemFont(ofSize: 11, weight: .medium)
        branchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        // A long branch name must truncate, not push the card (and the window) wider than the pane needs
        // — the labels themselves have to yield, not just their stack, or their intrinsic width holds the
        // footer open and the window can't reach its own min (ZEN-243).
        repoLabel.lineBreakMode = .byTruncatingTail
        branchLabel.lineBreakMode = .byTruncatingMiddle
        for label in [repoLabel, branchLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        branchIcon.imageScaling = .scaleProportionallyDown
        repoBranchStack.orientation = .horizontal
        repoBranchStack.spacing = 5
        repoBranchStack.alignment = .centerY
        repoBranchStack.setViews([repoLabel, branchIcon, branchLabel], in: .leading)
        // Yield (truncate) before the footer can grow a too-narrow window, same rule as the hints.
        repoBranchStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        repoBranchStack.translatesAutoresizingMaskIntoConstraints = false
        updateRepoBranch()

        hintsStack.orientation = .horizontal
        hintsStack.spacing = 16
        hintsStack.alignment = .centerY
        // Resist compression (hints shouldn't clip) but below 500 — a `.required` floor here would
        // *grow* the window on a display too narrow to fit the hints, the same NSWindow stay-put
        // mechanism the tree width dodges above. Hugging can stay high: refusing to grow past
        // intrinsic size never pushes the window.
        hintsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintsStack.setContentHuggingPriority(.required, for: .horizontal)
        hintsStack.translatesAutoresizingMaskIntoConstraints = false
        fillHints()

        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(repoBranchStack)
        footer.addSubview(hintsStack)
        NSLayoutConstraint.activate([
            repoBranchStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            repoBranchStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintsStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            hintsStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintsStack.leadingAnchor.constraint(greaterThanOrEqualTo: repoBranchStack.trailingAnchor, constant: 12),
        ])
        return footer
    }

    /// The footer identity: repo name always, then a branch glyph + the checked-out branch when there is
    /// one (collapsed when detached). Reads `Theme.current`, so a live theme swap recolors it.
    private func updateRepoBranch() {
        let chrome = Theme.current.chrome
        repoLabel.stringValue = repoName
        repoLabel.textColor = chrome.ink(alpha: 0.5)
        branchIcon.contentTintColor = chrome.ink(alpha: 0.5)
        let branch = displayedStatus?.currentBranch
        branchLabel.stringValue = branch ?? ""
        branchLabel.textColor = chrome.foreground.nsColor
        branchIcon.isHidden = branch == nil
        branchLabel.isHidden = branch == nil
    }

    /// The footer's key legend as compact keycaps, scoped to the focused pane so it stays lean: the tree
    /// shows the file/fold/base keys, the diff shows the change/select/yank/comment keys, and both end
    /// with layout + close. Switching panes (⌘h/⌘l, or bare h/l) is left off the legend on purpose — it's
    /// natural and discoverable, and spending two keycaps advertising it is what made the old footer
    /// crowded. Rebuilt on a theme/keymap change, a narrowness flip, and a focus move — every keycap bakes
    /// its colors in at construction, so it's re-created rather than mutated.
    private func fillHints() {
        hintsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Default to the tree legend for anything that isn't the diff itself (the base dropdown, or the
        // initial build before a pane holds focus) — the tree is the viewer's entry point.
        let diffIsFocused = window?.firstResponder === diffTable.scrollFocusTarget
        var groups: [(keys: [String], label: String)]
        if diffIsFocused {
            groups = [(["{", "}"], "change"), (["V"], "select"), (["y", "Y"], "yank"), (["⏎"], "comment")]
        } else {
            groups = [(["j", "k"], "files"), (["h", "l"], "fold"), (["b"], "base")]
        }
        // Layout only exists while wide — narrow force-folds to inline, so the toggle is disabled and its
        // key hidden (ZEN-243).
        if !isNarrow { groups.append((["\\"], "layout")) }
        groups.append((["esc"], "close"))
        // The ? full key sheet is shown in both focus states — it's the affordance that lets the rest of
        // the legend stay lean.
        groups.append((["?"], "keys"))
        for group in groups { hintsStack.addArrangedSubview(Self.hintGroup(keys: group.keys, label: group.label)) }
    }

    /// One legend entry for the footer: a compact keycap per key, then a muted caption. The keys sit
    /// tight together; the caption gets a wider gap so it reads as their shared label.
    private static func hintGroup(keys: [String], label: String) -> NSView {
        let caps: [NSView] = keys.map { KeycapView(shortcut: $0, size: .compact) }
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = Theme.current.chrome.ink(alpha: 0.45)
        let stack = NSStackView(views: caps + [caption])
        stack.orientation = .horizontal
        stack.spacing = 3  // tight between the keycaps
        stack.alignment = .centerY
        if let lastCap = caps.last { stack.setCustomSpacing(6, after: lastCap) }  // wider before the caption
        return stack
    }

    // MARK: loading

    private func reload(showSpinner: Bool) {
        loadToken += 1
        let token = loadToken
        if showSpinner { showMessage("Loading…") }
        guard !loadInFlight else {
            pendingReload = true
            pendingReloadShowsSpinner = pendingReloadShowsSpinner || showSpinner
            return
        }
        startLoad(token: token)
    }

    private func startLoad(token: Int) {
        loadInFlight = true
        loader(baseOverride, headOverride) { [weak self] result in
            guard let self else { return }
            self.loadInFlight = false
            if token == self.loadToken {
                // Branch metadata is refreshed once per current status result. Keeping it ahead of the
                // unchanged-status guard lets a ref change update the picker even when the diff did not.
                self.refreshBranches()
                switch result {
                case .success(let status):
                    if status != self.displayedStatus {
                        self.evictStaleHighlights(from: self.displayedStatus, to: status)
                        self.apply(status)
                    }
                case .failure(let failure):
                    self.displayedStatus = nil
                    self.updateRepoBranch()
                    self.showMessage(self.failureMessage(for: failure))
                }
            }
            if self.pendingReload {
                let showSpinner = self.pendingReloadShowsSpinner
                self.pendingReload = false
                self.pendingReloadShowsSpinner = false
                if showSpinner { self.showMessage("Loading…") }
                self.startLoad(token: self.loadToken)
            }
        }
    }

    /// Re-read the repo without disturbing the current surface while the load is in flight. The
    /// watcher owns when to call this; the overlay keeps the reaction identical to every other
    /// background reload, including stale-load rejection and unchanged-status no-ops.
    func refresh() {
        reload(showSpinner: false)
    }

    /// Evict only the highlight-cache keys a changed reload actually moved, instead of wiping the whole
    /// repo's spans (ZEN-261). A file whose `FileDiff` is byte-identical between the old and new load
    /// keeps its cached spans and repaints with no re-parse; only the changed files (or ones that
    /// vanished) pay the tree-sitter cost. Wiping everything made a warm reopen — the common case, since
    /// you reopen the diff *because* you changed something — blank and re-parse like a cold open.
    private func evictStaleHighlights(from old: GitDiffRunner.StatusLoad?, to new: GitDiffRunner.StatusLoad) {
        guard let old else { return }  // first load: nothing cached to reconcile against
        let newByKey = Dictionary(
            (new.unstaged + new.staged + new.committed).map { ($0.highlightKey, $0) },
            uniquingKeysWith: { first, _ in first })
        // A key is stale when its file changed content (same key, different `FileDiff`) or is gone from
        // the new load (no entry). A brand-new file isn't cached yet, so it needs no eviction.
        var stale: Set<String> = []
        for file in old.unstaged + old.staged + old.committed where newByKey[file.highlightKey] != file {
            stale.insert(file.highlightKey)
        }
        highlightStore.evict(stale)
    }

    /// Render a status: rebuild the tree, then put the reader back where they were. The rebuild is
    /// unavoidable (the `NSOutlineView` holds its rows by object identity, and a changed status means
    /// new objects), so the folds, the selected file and the cursor line are carried across it by value
    /// instead — from the session on the first load, off the live view on every one after (ZEN-233).
    private func apply(_ status: GitDiffRunner.StatusLoad) {
        let place = pendingPlace ?? currentPlace()
        pendingPlace = nil
        displayedStatus = status
        updateBaseHeader()  // reflect the base this load resolved to
        updateRepoBranch()  // reflect the checked-out branch this load carries

        let controller = DiffTreeOutlineController(
            sections: DiffOutlineItem.sections(from: status),
            onSelect: { [weak self] file in self?.selectFile(file) })
        outlineController = controller
        outline.dataSource = controller
        outline.delegate = controller
        outline.reloadData()
        // Expand everything, then re-close what the reader had closed: a directory this load is the
        // first to show has never been folded, so it belongs open like every other new row.
        outline.expandItem(nil, expandChildren: true)
        collapse(place.collapsed, in: controller.roots)

        selectedFilePath = nil
        guard let target = resolveSelection(place, in: controller), let file = target.fileDiff else {
            prefetcher.schedule(status, excluding: nil)  // no files — just retire any prior pass
            showMessage("No changes")
            return
        }
        // The cursor only carries within one file; landing on a different one starts at its first line.
        pendingCursor = place.cursorLine.flatMap { line in
            file.path == place.selectedPath ? (path: file.path, line: line) : nil
        }
        // A file inside a folder the reader folded shut has no row to select. Its diff still shows —
        // they folded the folder, they didn't close the file.
        let row = outline.row(forItem: target)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        selectFile(file)
        // Warm every other file in the background so navigating to it is a highlighted cache hit.
        prefetcher.schedule(status, excluding: file.highlightKey)
    }

    /// Where the viewer is looking right now — the folded rows, the selected one, and the cursor's line.
    private func currentPlace() -> DiffViewerPlace {
        var place = DiffViewerPlace()
        if let roots = outlineController?.roots { place.collapsed = collapsedIdentities(in: roots) }
        let selected = outline.item(atRow: outline.selectedRow) as? DiffOutlineItem
        place.selectedIdentity = selected?.identity
        // The shown file, not the selected row's: the selection can sit on a directory or a section
        // header, and it's the file in the right pane that the reader is actually reading.
        place.selectedPath = selectedFilePath
        place.cursorLine = diffTable.cursorLine
        return place
    }

    /// The identities of every folded row, including ones nested inside another fold (the outline keeps
    /// their state while they're hidden, and so does this).
    private func collapsedIdentities(in items: [DiffOutlineItem]) -> Set<String> {
        var folded: Set<String> = []
        for item in items where !item.children.isEmpty {
            if !outline.isItemExpanded(item) { folded.insert(item.identity) }
            folded.formUnion(collapsedIdentities(in: item.children))
        }
        return folded
    }

    /// Re-close the folded rows, children before parents: collapsing a parent first would hide its
    /// children, and a hidden row can't be told to fold.
    private func collapse(_ identities: Set<String>, in items: [DiffOutlineItem]) {
        guard !identities.isEmpty else { return }
        for item in items where !item.children.isEmpty {
            collapse(identities, in: item.children)
            if identities.contains(item.identity) { outline.collapseItem(item) }
        }
    }

    /// Which file the rebuilt tree should show: the same row when it's still there; else the same file
    /// wherever it moved to (a `git add` mid-review carries a file from Unstaged to Staged — a different
    /// row, the same file to whoever is reading it); else the first file, where a fresh load lands.
    private func resolveSelection(
        _ place: DiffViewerPlace, in controller: DiffTreeOutlineController
    ) -> DiffOutlineItem? {
        let files = controller.fileItems
        if let identity = place.selectedIdentity, let match = files.first(where: { $0.identity == identity }) {
            return match
        }
        if let path = place.selectedPath, let match = files.first(where: { $0.fileDiff?.path == path }) {
            return match
        }
        return files.first
    }

    private func selectFile(_ file: FileDiff) {
        // Dedup: the load both selects the row (firing this via the delegate) and calls here directly,
        // and re-selecting the exact shown diff shouldn't re-render. Path alone is not identity: one
        // path can have different hunks in Unstaged and Staged at the same time.
        guard selectedFilePath != file.path || currentFileDiff != file else { return }
        selectedFilePath = file.path
        currentFileDiff = file
        messageLabel.isHidden = true
        diffTable.isHidden = false
        renderCurrentFile()
    }

    /// The layout a diff renders in. A narrow pane force-folds to inline — that view is objectively best
    /// when two columns can't fit, so it isn't a choice (the toggle is disabled and its hint hidden while
    /// narrow). While wide: the session pin (the `\` toggle), else the config default (ZEN-243).
    private var effectiveLayout: GeneralConfig.DiffLayout {
        isNarrow ? .inline : (layoutOverride ?? GeneralConfig.current.diffLayout)
    }

    /// The diff pane resized — re-evaluate the fold, refresh the footer hints if narrowness flipped, and
    /// re-render only if the effective layout actually changed.
    @objc private func paneFrameDidChange() {
        if updateIsNarrow(forWidth: diffTable.bounds.width) { fillHints() }
        reconcileLayout()
    }

    /// Fold below `foldWidth`, unfold above `unfoldWidth` — a dead-band so a resize landing between the
    /// two thresholds keeps its last decision. Returns whether the narrow state actually flipped (the
    /// caller refreshes the footer hints only then).
    @discardableResult
    private func updateIsNarrow(forWidth width: CGFloat) -> Bool {
        if isNarrow, width > Self.unfoldWidth {
            isNarrow = false
        } else if !isNarrow, width < Self.foldWidth {
            isNarrow = true
        } else {
            return false
        }
        return true
    }

    /// The single funnel for anything that can change `effectiveLayout` without a new file: a resize
    /// crossing the fold/unfold band, a config-default change, or the `\` toggle. Re-renders only when the
    /// effective layout truly differs from what's on screen, so a resize tick or theme change never
    /// resets the diff's scroll or current line. Returns whether it re-rendered.
    @discardableResult
    private func reconcileLayout() -> Bool {
        guard currentFileDiff != nil, effectiveLayout != renderedLayout else { return false }
        renderCurrentFile(keepingSelection: true)  // same file — the cursor and selection carry over
        return true
    }

    /// The layout toggle (bare `\`) flips the pinned layout for the session; disabled while narrow,
    /// where inline is forced and the choice doesn't exist.
    func toggleLayout() {
        guard guardComposer(), !isNarrow else { return }
        layoutOverride = effectiveLayout == .sideBySide ? .inline : .sideBySide
        reconcileLayout()
    }

    /// (Re)render the shown file in the effective layout — no git re-run. Called on file select and on
    /// a layout change (a resize crossing the fold band, the toggle command, or a config-default change).
    /// Safety cap: if the off-main highlighter hasn't answered by now, paint plain rather than hold the
    /// view. Only trips for a pathologically slow parse/fetch — the highlight normally lands in tens of ms.
    private static let highlightSafetyCap: TimeInterval = 0.8

    /// `keepingSelection` is true for a re-render of the *same* file (a layout flip or a resize
    /// crossing the fold band), where the cursor and any running selection must survive — you were
    /// mid-review and the layout change wasn't about the selection.
    private func renderCurrentFile(keepingSelection: Bool = false) {
        guard let file = currentFileDiff else { return }
        let key = file.highlightKey  // scope+base+path — the same path in two slices caches separately
        // Already highlighted this file (a revisit, a layout flip, or a reopen)? Paint it highlighted
        // immediately — no flash, no re-parse. A cached value of nil means "resolved, no spans".
        if let cached = highlightStore.cached(key) {
            renderRows(file, spans: cached, keepingSelection: keepingSelection)
            return
        }
        // Won't ever highlight (no repo on disk, or an extension no grammar claims) — plain now is the
        // final state. A path with no extension is not a "no": its blob may still name a language
        // through a shebang or modeline, so it goes on to the enrich path like any other (ZEN-329).
        guard
            FileManager.default.fileExists(atPath: repoRoot.path),
            SyntaxLanguage.mayHighlight(path: file.path)
        else {
            highlightStore.store(key, nil)
            renderRows(file, spans: nil, keepingSelection: keepingSelection)
            return
        }
        // Resolvable + uncached: withhold the first paint until the highlight lands, so even a cold open
        // goes straight from the loading state to highlighted — never a flash of unhighlighted text. The
        // token drops a stale file-switch; the safety cap paints plain if the highlighter never answers.
        //
        // Extensionless files take this same single-paint path deliberately, rather than painting plain
        // and repainting when the sniff answers. A second paint runs `renderRows`, which closes an open
        // comment composer (losing whatever was typed into it) and re-centres the cursor row, so a
        // reader who started working in the gap would lose it. Waiting costs nothing extra: `enrich`
        // calls back whether or not it resolved a language, so a config that resolves to nothing paints
        // as soon as its one git spawn returns, not at the safety cap.
        //
        // Clear the pane first. Withholding the paint would otherwise leave the *previously* selected
        // file's rows on screen under the new selection for as long as the fetch+parse takes (up to the
        // safety cap on a big file, a cold object store, or a network volume) — showing content that
        // doesn't match what's selected, which reads as a click that did nothing.
        diffTable.show([])
        highlightToken += 1
        let token = highlightToken
        var painted = false
        DiffHighlighter.enrich(file: file, repoRoot: repoRoot) { [weak self] spans in
            guard let self else { return }
            self.highlightStore.store(key, spans)
            guard token == self.highlightToken, self.currentFileDiff?.highlightKey == key else { return }
            painted = true
            self.renderRows(file, spans: spans)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightSafetyCap) { [weak self] in
            guard let self, !painted, token == self.highlightToken, self.currentFileDiff?.highlightKey == key
            else { return }
            self.renderRows(file, spans: nil)
        }
    }

    /// Build and show the rows for `file` in the effective layout, with optional syntax spans. A cursor
    /// line a reload left waiting for this file is spent here — one paint gets it, and the ones the
    /// highlight race loses don't (`renderCurrentFile` guards those out anyway).
    private func renderRows(_ file: FileDiff, spans: DiffFileSpans?, keepingSelection: Bool = false) {
        // The box hangs off a row index, and these rows are about to be replaced — a comment left
        // open across that would point at a line the diff no longer has there.
        closeComposer()
        let layout = effectiveLayout
        renderedLayout = layout
        let carried = pendingCursor.flatMap { $0.path == file.path ? $0.line : nil }
        pendingCursor = nil
        diffTable.show(
            layout == .inline
                ? UnifiedDiff.rows(for: file, spans: spans) : SideBySideDiff.rows(for: file, spans: spans),
            preservingSelection: keepingSelection, restoringCursor: carried)
    }

    private func showMessage(_ text: String) {
        selectedFilePath = nil
        currentFileDiff = nil
        renderedLayout = nil
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

    // MARK: test hooks

    /// The number of rows the file tree currently shows (sections + expanded files).
    var treeRowCountForTesting: Int { outline.numberOfRows }
    /// The path of the file whose diff is in the right pane, or nil when a message is shown.
    var selectedFilePathForTesting: String? { selectedFilePath }
    /// The number of visual diff rows rendered in the right pane.
    var diffRowCountForTesting: Int { diffTable.rowCountForTesting }
    var renderedDiffRowsForTesting: [DiffRow] { diffTable.rows }
    /// Re-run the loader the way a background refresh does, so a test can assert what a load carrying
    /// *changed* content does to the highlight cache.
    func reloadForTesting() { refresh() }

    var renderedDiffLayoutForTesting: GeneralConfig.DiffLayout? { renderedLayout }
    /// The footer's repo name, and the branch it shows (nil when the branch glyph/name are collapsed).
    var footerRepoNameForTesting: String { repoLabel.stringValue }
    var footerBranchForTesting: String? { branchLabel.isHidden ? nil : branchLabel.stringValue }
    /// The captions of the footer's key-hint legend (e.g. "panes", "fold", "layout"), so a test can
    /// assert the legend scopes to the focused pane and drops "layout" while the pane is narrow.
    var footerHintCaptionsForTesting: [String] {
        hintsStack.arrangedSubviews.compactMap { group in
            (group as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSTextField }.last?.stringValue
        }
    }
    /// The live diff-pane width — for a resize-driven fold test to confirm the pane actually shrank.
    var paneWidthForTesting: CGFloat { diffTable.contentWidthForTesting }
    /// Drive a tree selection the way a click/arrow would, so a test exercises the real selection path.
    func selectRowForTesting(_ row: Int) {
        outline.selectRowIndexes([row], byExtendingSelection: false)
    }
    /// The open comment composer, or nil — so a test can drive its real controls and assert what a
    /// send actually composed.
    var composerForTesting: DiffCommentComposer? { composer }
    /// Whether the `?` key-reference popover is currently shown.
    var isKeySheetShownForTesting: Bool { keySheet?.isShown == true }
    /// Whether the base dropdown header is shown (a base resolved for the committed slice).
    var isBaseHeaderShownForTesting: Bool { !baseHeader.isHidden }
    /// The base dropdown, for asserting its branch list and driving a pick through the real control.
    var baseDropdownForTesting: Dropdown { baseDropdown }
    var headDropdownForTesting: Dropdown { headDropdown }
    var isBaseDropdownShownForTesting: Bool { !baseDropdown.isHidden }
    var isHeadDropdownShownForTesting: Bool { !headDropdown.isHidden }
    var baseHeaderHeightForTesting: CGFloat { baseHeaderHeight.constant }
    var treeWidthForTesting: CGFloat {
        (treeWidthProportional.firstItem as? NSView)?.frame.width ?? 0
    }
    var treeWidthPriorityForTesting: NSLayoutConstraint.Priority { treeWidthProportional.priority }
    var treeTitleCompressionPriorityForTesting: NSLayoutConstraint.Priority {
        headDropdown.contentCompressionResistancePriority(for: .horizontal)
    }
    /// The root git reads resolve against — the picked branch's worktree, or the repo the viewer opened
    /// on. Exposed because the highlighter following the loader is the whole point of `retargetRepoRoot`.
    var repoRootForTesting: URL { repoRoot }
    /// The host watches the same root the loader and highlighter read. Unlike the testing alias, this
    /// is part of the overlay-host lifecycle seam.
    var effectiveRepoRoot: URL { repoRoot }
    /// Choose a base branch the way the dropdown's `onChange` does, to exercise the base-override load.
    func chooseBaseForTesting(_ branch: String) {
        guard let index = baseItems.firstIndex(of: branch) else { return }
        chooseBaseAt(index)
    }
    /// The file tree, so a test can send a real `keyDown` (Esc / Up-at-top / Return-to-fold) through
    /// `NavOutlineView`'s handler rather than only its selection path.
    var treeOutlineForTesting: NSOutlineView { outline }
    /// The diff pane, so a test can send real `keyDown`s down the vim path and read back what the
    /// selection actually became.
    var diffPaneForTesting: DiffPaneTable { diffTable }
    /// Which pane holds first responder, for asserting `handleNavChord`'s focus moves landed.
    var isTreeFocusedForTesting: Bool { window?.firstResponder === outline }
    var isDiffFocusedForTesting: Bool { window?.firstResponder === diffTable.scrollFocusTarget }
    var isBaseDropdownFocusedForTesting: Bool { window?.firstResponder === baseDropdown }
    var isHeadDropdownFocusedForTesting: Bool { window?.firstResponder === headDropdown }
}

/// A clip view that refuses to scroll horizontally: it pins the visible rect's x to 0, so the single
/// wide column can never pan the file tree sideways whatever rounding leaves the document a hair wider
/// than the clip (the tree only ever truncates names, so nothing is lost to the clamp).
private final class LockedHorizontalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.x = 0
        return rect
    }
}

/// The file tree's outline view. Accepts first responder even when empty (so keystrokes never leak to
/// the terminal behind the card). Navigation is driven by forwarded pane chords, not Tab; the only
/// key it claims is Esc, so it closes the viewer instead of the outline eating it as a deselect.
private final class NavOutlineView: NSOutlineView {
    var onEscape: (() -> Void)?
    /// Move focus up out of the tree to the base dropdown — fired by Up at the top row, so the
    /// dropdown is reachable by the arrows without leaving the keyboard.
    var onFocusBase: (() -> Void)?
    /// Ctrl-D / Ctrl-U half-page the diff pane while the tree keeps focus (+1 down / -1 up), so a file
    /// can be scanned without stepping over into the diff.
    var onHalfPageDiff: ((Int) -> Void)?
    /// Ctrl-j/k / Ctrl-↑↓ soft half-page the tree's own file selection (+1 down / -1 up), centered.
    var onPageFiles: ((Int) -> Void)?
    /// j / k move to the next / previous file, so the tree reads the same way as the diff pane.
    var onMoveFile: ((Int) -> Void)?
    /// Bare `\` — flip the viewer between inline and side-by-side (ZEN-262).
    var onToggleLayout: (() -> Void)?
    /// `l` on a file (nvim "open") — hand focus to the diff pane.
    var onFocusDiff: (() -> Void)?
    /// Bare `q` — close the viewer.
    var onClose: (() -> Void)?
    /// Bare `?` — toggle the key-reference popover.
    var onShowKeys: (() -> Void)?
    /// Focus landed here (a click or a keyboard move) — the overlay resyncs focus styling and the
    /// footer legend, so a mouse click between panes tracks the same as ⌘h/⌘l.
    var onBecameFirstResponder: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecameFirstResponder?() }
        return ok
    }

    /// Size the sole name column to fill the enclosing scroll view. AppKit's own column-autoresizing
    /// styles are delta-based (they nudge the column by the *change* in the table's width since the
    /// last resize, not a fresh "fill remaining space" calculation), so the very first resize — which
    /// for this tree fires while `DiffViewerOverlay` is still mid-`init()`, before the surrounding Auto
    /// Layout has ever resolved a real width — permanently anchors the column to the wrong size.
    /// Reading from `enclosingScrollView.contentSize` instead of `self.bounds` matters too: the
    /// outline's own bounds is exactly the value that legacy machinery leaves in a bad state, where the
    /// scroll view's content size is the one number here that Auto Layout actually resolves (ZEN-226).
    override func layout() {
        super.layout()
        guard let nameColumn = outlineTableColumn,
            let contentWidth = enclosingScrollView?.contentSize.width
        else { return }
        let target = max(40, contentWidth - intercellSpacing.width)
        if abs(nameColumn.width - target) > 0.5 {
            nameColumn.width = target
        }
    }

    // Level-0 section rows get no indentation, so their disclosure triangle lands hard against the
    // column edge — left of the selection pill's inner edge, poking out its left border. Push sections
    // right by one indent level so their chevron lines up with the folder chevrons *inside* the pill;
    // shifting both the disclosure and the content cell keeps the chevron-to-title gap intact.
    private func sectionShift(forRow row: Int) -> CGFloat {
        level(forRow: row) == 0 ? indentationPerLevel : 0
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var f = super.frameOfOutlineCell(atRow: row)
        f.origin.x += sectionShift(forRow: row)
        return f
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var f = super.frameOfCell(atColumn: column, row: row)
        let shift = sectionShift(forRow: row)
        f.origin.x += shift
        f.size.width -= shift
        return f
    }

    override func keyDown(with event: NSEvent) {
        if let direction = DiffPaneTable.halfPageDirection(for: event) {
            onHalfPageDiff?(direction)
            return
        }
        if let direction = DiffPaneTable.pageDirection(for: event) {
            onPageFiles?(direction)
            return
        }
        if let command = DiffPaneTable.viewerCommand(for: event) {
            switch command {
            case .toggleLayout: onToggleLayout?()
            case .focusBase: onFocusBase?()
            case .close: onClose?()
            case .showKeys: onShowKeys?()
            }
            return
        }
        // Only j/k are claimed from the vim set here: the rest acts on a diff selection, which the
        // tree doesn't have. They'd read as dead keys either way, so the tree leaves them alone.
        switch DiffPaneTable.vimKey(for: event) {
        case .down:
            onMoveFile?(1)
            return
        case .up:
            onMoveFile?(-1)
            return
        default:
            break
        }
        // nvim-tree fold: h / ← collapse (or step to the parent), l / → expand (or open a file into
        // the diff). The arrows mirror the bare letters.
        if let fold = foldDirection(for: event) {
            fold == .left ? foldLeftOrParent() : expandOrOpen()
            return
        }
        switch KeyboardFocus.key(for: event) {
        case .escape:
            onEscape?()
            return
        case .up where selectedRow <= 0:
            onFocusBase?()  // at the top already — step up to the base dropdown
            return
        case .activate:
            // Return/Enter on a folder or section folds it, matching h/l; a file just stays selected
            // (its diff is already shown).
            if let item = item(atRow: selectedRow), isExpandable(item) {
                if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    private enum FoldDirection { case left, right }

    /// Decode a fold keystroke: bare `h` / ← collapse-ward, bare `l` / → expand-ward. The letters are
    /// truly bare (any reservable modifier falls through, so Shift-h / ⌘h aren't folds); the arrows go
    /// through `KeyboardFocus.key`, which ignores modifiers the same way the rest of the tree's arrow
    /// handling does.
    private func foldDirection(for event: NSEvent) -> FoldDirection? {
        switch KeyboardFocus.key(for: event) {
        case .left: return .left
        case .right: return .right
        default: break
        }
        guard event.modifierFlags.intersection(DiffPaneTable.reservableModifiers).isEmpty else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "h": return .left
        case "l": return .right
        default: return nil
        }
    }

    /// `h` / ←: collapse an open folder; on a leaf or already-collapsed row, step to the parent so a
    /// second press walks up the tree (nvim-tree's "close, else go up").
    private func foldLeftOrParent() {
        guard let item = item(atRow: selectedRow) else { return }
        if isExpandable(item), isItemExpanded(item) {
            collapseItem(item)
            return
        }
        guard let parent = parent(forItem: item) else { return }
        let parentRow = row(forItem: parent)
        guard parentRow >= 0 else { return }
        selectRowIndexes([parentRow], byExtendingSelection: false)
        scrollRowToVisible(parentRow)
    }

    /// `l` / →: expand a collapsed folder; on a file, hand focus to the diff (nvim-tree's "open").
    private func expandOrOpen() {
        guard let item = item(atRow: selectedRow) else { return }
        if isExpandable(item) {
            if !isItemExpanded(item) { expandItem(item) }
        } else {
            onFocusDiff?()
        }
    }
}
