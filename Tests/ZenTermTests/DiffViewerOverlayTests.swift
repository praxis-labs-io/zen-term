import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the diff viewer, driven through the real outline view in a window. The git
/// work is a fake `loader`, so no repo. State-only assertions would pass while the tree was dead, the
/// failure mode the project's interaction-test rule guards against.
final class DiffViewerOverlayTests: WindowTestCase {
    private var window: NSWindow?
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        // Pin the diff-layout default so the tester's own config can't decide the initial layout.
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private final class LoaderSpy {
        var calls = 0
        /// The `base` the overlay asked each load for — nil on the default-base load, the picked branch
        /// after a base override.
        var lastBase: String?
        /// A `var` so a test can hand the *next* load different content — a changed reload is the whole
        /// trigger for the restore this file exercises (ZEN-233).
        var status: GitDiffRunner.StatusLoad
        let failure: GitDiffRunner.Failure?
        let branches: [String]
        /// The head picker's options. Its `worktree` is what decides whether a pick reads a whole
        /// working tree or only the committed slice (ZEN-313).
        /// A `var` so a test can hand the *next* refresh a different branch list — a branch
        /// vanishing between refreshes is what the reconciliation exists for.
        var heads: [GitDiffRunner.BranchOption]
        /// The head the overlay asked each load for — nil while it is showing the checkout's own.
        var lastHead: GitDiffRunner.BranchOption?
        var branchCalls = 0
        var headCalls = 0
        init(
            status: GitDiffRunner.StatusLoad, failure: GitDiffRunner.Failure?, branches: [String],
            heads: [GitDiffRunner.BranchOption] = []
        ) {
            self.status = status
            self.failure = failure
            self.branches = branches
            self.heads = heads
        }
        func load(
            _ base: String?, _ head: GitDiffRunner.BranchOption?,
            _ completion: (DiffViewerOverlay.StatusResult) -> Void
        ) {
            calls += 1
            lastBase = base
            lastHead = head
            if let failure {
                completion(.failure(failure))
            } else {
                completion(.success(status))
            }
        }
    }

    private func makeStatus(
        unstaged: [FileDiff] = [], staged: [FileDiff] = [], committed: [FileDiff] = [],
        base: (branch: String, sha: String)? = nil
    ) -> GitDiffRunner.StatusLoad {
        GitDiffRunner.StatusLoad(
            unstaged: unstaged, staged: staged, committed: committed,
            baseBranch: base?.branch, baseSHA: base?.sha, currentBranch: "feature")
    }

    private func mount(
        unstaged: [FileDiff] = [], staged: [FileDiff] = [], committed: [FileDiff] = [],
        base: (branch: String, sha: String)? = nil, branches: [String] = [],
        heads: [GitDiffRunner.BranchOption] = [],
        failure: GitDiffRunner.Failure? = nil, onCancel: @escaping () -> Void = {},
        onRepoRootChange: @escaping (URL) -> Void = { _ in },
        // A shared session mounts overlay B on the state overlay A left behind — the reopen path.
        session: DiffViewerSession? = nil
    ) -> (overlay: DiffViewerOverlay, spy: LoaderSpy) {
        let status = makeStatus(unstaged: unstaged, staged: staged, committed: committed, base: base)
        let spy = LoaderSpy(status: status, failure: failure, branches: branches, heads: heads)
        // A path that doesn't exist, so the syntax highlighter no-ops (these tests exercise layout and
        // selection, not highlighting) and never spawns git. Its last component is the footer's repo
        // name, so it reads `repo`.
        let session =
            session
            ?? DiffViewerSession(repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo/repo"))
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            session: session,
            loader: { base, head, completion in spy.load(base, head, completion) },
            branchesLoader: { completion in
                spy.branchCalls += 1
                completion(spy.branches)
            },
            headsLoader: { completion in
                spy.headCalls += 1
                completion(spy.heads)
            },
            sendTargets: { [] },
            sender: { _, _, _ in },
            onRepoRootChange: onRepoRootChange,
            onCancel: onCancel)
        let win = NSWindow(
            // Wide enough that the diff pane defaults to side-by-side (above the auto-fold threshold);
            // the fold tests resize narrower to cross it.
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return (overlay, spy)
    }

    private func file(_ path: String, added: Int = 1, removed: Int = 1) -> FileDiff {
        var lines: [DiffLine] = [DiffLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "ctx")]
        for index in 0..<removed {
            lines.append(DiffLine(kind: .removed, oldLineNumber: 2 + index, newLineNumber: nil, text: "old \(index)"))
        }
        for index in 0..<added {
            lines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 2 + index, text: "new \(index)"))
        }
        return FileDiff(
            path: path, oldPath: nil, changeKind: .modified,
            hunks: [Hunk(header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1, lines: lines)])
    }

    private func file(_ path: String, scope: DiffScope, addedLine: String) -> FileDiff {
        FileDiff(
            path: path, oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -0,0 +1 @@",
                    oldStart: 0,
                    newStart: 1,
                    lines: [
                        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 1, text: addedLine)
                    ])
            ],
            scope: scope)
    }

    private func renderedTexts(_ overlay: DiffViewerOverlay) -> [String] {
        overlay.renderedDiffRowsForTesting.flatMap { row in
            switch row {
            case .hunkHeader(let text): return [text]
            case .split(let left, let right): return [left?.text, right?.text].compactMap { $0 }
            case .unified(let text, _, _, _, _): return [text]
            }
        }
    }

    // MARK: tests

    func test_initialLoad_loadsOnceAndFillsTheTreeUnderASection() {
        let (overlay, spy) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        XCTAssertEqual(spy.calls, 1)
        // Unstaged section + a / (b / One.swift) + Two.swift, expanded => 5 rows.
        XCTAssertEqual(overlay.treeRowCountForTesting, 5)
    }

    func test_load_autoSelectsFirstFileIntoTheRightPane() {
        let (overlay, _) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/b/One.swift")
        XCTAssertGreaterThan(overlay.diffRowCountForTesting, 0)
    }

    func test_samePathInTwoScopes_switchesTheRenderedDiffWithTheRealTreeSelection() {
        let path = "Probe.txt"
        let (overlay, _) = mount(
            unstaged: [file(path, scope: .unstaged, addedLine: "working tree")],
            staged: [file(path, scope: .staged, addedLine: "index")])

        XCTAssertTrue(renderedTexts(overlay).contains("working tree"))

        overlay.selectRowForTesting(3)  // Staged section is row 2; its Probe.txt is row 3.
        XCTAssertTrue(
            renderedTexts(overlay).contains("index"),
            "the same path in Staged is a different diff, not a duplicate selection")

        overlay.selectRowForTesting(1)  // Back to Unstaged/Probe.txt.
        XCTAssertTrue(renderedTexts(overlay).contains("working tree"))
    }

    /// The bare `\` layout key must actually swap the rendered pane, not just flip a flag — the "control
    /// looks wired but the screen never moved" failure. Driven through a real `\` keyDown into the diff
    /// pane (ZEN-262); the row count changes because side-by-side pairs +/- lines while inline lists each,
    /// so a stale render would keep the old count.
    func test_backslashKey_swapsTheRenderedLayoutLive_andBack() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide)
        let sideBySideRows = overlay.diffRowCountForTesting

        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: bareKey("\\", keyCode: 42))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)
        XCTAssertNotEqual(
            overlay.diffRowCountForTesting, sideBySideRows,
            "the pane must re-render in the new layout, not just flip a flag")

        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: bareKey("\\", keyCode: 42))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide, "toggles back")
        XCTAssertEqual(overlay.diffRowCountForTesting, sideBySideRows)
    }

    /// The footer shows the repo name always, and the checked-out branch the load carried — proving the
    /// StatusLoad → footer plumbing is live, not just that a label exists.
    func test_footer_showsRepoNameAndLoadedBranch() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])

        XCTAssertEqual(overlay.footerRepoNameForTesting, "repo")
        XCTAssertEqual(overlay.footerBranchForTesting, "feature")
    }

    // MARK: auto-fold on narrow width (ZEN-243)

    /// Resize the overlay to a real width and force a layout pass so `DiffPaneTable.layout()` fires the
    /// width callback. The overlay is `translatesAutoresizingMaskIntoConstraints = false`, so its frame
    /// isn't expressed to the constraint engine on its own — flip it authoritative for the test so the
    /// card (and thus the diff pane) recomputes against the new width.
    private func resize(_ overlay: DiffViewerOverlay, toWidth width: CGFloat) {
        overlay.translatesAutoresizingMaskIntoConstraints = true
        overlay.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        overlay.layoutSubtreeIfNeeded()
    }

    /// Narrowing the diff pane below the fold width auto-folds to inline without a pin; widening back past
    /// the unfold width auto-restores side-by-side. A dead `onWidthChange` wire, or a `reconcileLayout()`
    /// that never re-renders, would leave this stuck on the initial layout. Widths are chosen so the diff
    /// pane lands well clear of the fold/unfold thresholds (~660/720 today), not boundary-flaky.
    func test_narrowingThePane_autoFoldsToInline_andWideningRestoresSideBySide() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide)

        resize(overlay, toWidth: 480)
        XCTAssertLessThan(overlay.paneWidthForTesting, 300, "sanity: the pane actually shrank well below the fold")
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline, "too narrow for two columns")

        resize(overlay, toWidth: 1200)
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide, "wide again — auto-unfolds")
    }

    /// While narrow, inline is forced and the `\` layout toggle is disabled: it must not touch the pin.
    /// Since a narrow pane renders inline regardless of the override, a broken guard is only observable on
    /// a later widen — so pin inline while wide (differs from the side-by-side default), narrow, toggle
    /// (must no-op), then widen and confirm the pin survived. Without the guard the narrow toggle would
    /// flip the pin to side-by-side and this final assertion would catch it.
    func test_whileNarrow_layoutToggleIsDisabled_andDoesNotTouchThePin() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        // Pin inline while wide.
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: bareKey("\\", keyCode: 42))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)

        resize(overlay, toWidth: 480)
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline, "narrow forces inline")

        // A no-op while narrow.
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: bareKey("\\", keyCode: 42))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)

        resize(overlay, toWidth: 1200)
        XCTAssertEqual(
            overlay.renderedDiffLayoutForTesting, .inline, "the wide pin must survive a no-op narrow toggle")
    }

    /// A pin set while wide governs only the wide state, and survives a narrow→wide round trip: it returns
    /// to the pinned layout, not the config default. (Default is side-by-side; the pin is inline.)
    func test_widePin_survivesNarrowRoundTrip() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide)

        // Pin inline while wide.
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: bareKey("\\", keyCode: 42))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)

        resize(overlay, toWidth: 480)
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline, "narrow forces inline")

        resize(overlay, toWidth: 1200)
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline, "wide again — pin honored, not the default")
    }

    /// The "layout" shortcut hint is shown while wide and hidden while narrow, matching the disabled toggle.
    func test_layoutHint_shownWhileWide_hiddenWhileNarrow() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertTrue(overlay.footerHintCaptionsForTesting.contains("layout"), "shown while wide")

        resize(overlay, toWidth: 480)
        XCTAssertFalse(overlay.footerHintCaptionsForTesting.contains("layout"), "hidden while narrow")
    }

    func test_selectingAFileInTheTree_drivesTheRightPane() {
        let (overlay, _) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        // Rows: Unstaged=0, a=1, b=2, One.swift=3, Two.swift=4.
        overlay.selectRowForTesting(4)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/Two.swift")
    }

    func test_selectingASectionRow_doesNotChangeTheShownFile() {
        let (overlay, _) = mount(unstaged: [file("a/b/One.swift"), file("a/Two.swift")])

        overlay.selectRowForTesting(0)  // the "Unstaged" section header (not selectable)

        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/b/One.swift")  // unchanged
    }

    func test_multipleSlices_eachGetTheirOwnSection() {
        let (overlay, _) = mount(
            unstaged: [file("U.swift")], staged: [file("S.swift")], committed: [file("C.swift")],
            base: (branch: "main", sha: "abc1234"))

        // Three sections, each with one file => 6 rows (the base lives in the header, not the tree).
        XCTAssertEqual(overlay.treeRowCountForTesting, 6)
    }

    func test_emptyStatus_showsNoTreeAndNoSelectedFile() {
        let (overlay, _) = mount()

        XCTAssertEqual(overlay.treeRowCountForTesting, 0)
        XCTAssertNil(overlay.selectedFilePathForTesting)
    }

    func test_gitError_showsNoTreeAndNoSelectedFile() {
        let (overlay, _) = mount(failure: .gitError("fatal: bad thing"))

        XCTAssertEqual(overlay.treeRowCountForTesting, 0)
        XCTAssertNil(overlay.selectedFilePathForTesting)
    }

    // MARK: base dropdown

    func test_baseDropdown_shownWithTheBranchListAndCurrentBaseSelected_whenABaseResolves() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])

        XCTAssertTrue(overlay.isBaseHeaderShownForTesting)
        // The trigger reads "Base: <branch>"; the list rows stay bare branch names.
        XCTAssertEqual(overlay.baseDropdownForTesting.buttonTitleForTesting, "Base: main")
    }

    func test_baseDropdown_hidden_whenNoBaseResolves() {
        let (overlay, _) = mount(unstaged: [file("U.swift")])  // no committed slice, no base

        XCTAssertFalse(overlay.isBaseHeaderShownForTesting)
    }

    // MARK: branch (head) dropdown — ZEN-313

    private static func head(_ name: String, worktree: String? = nil, current: Bool = false)
        -> GitDiffRunner.BranchOption
    {
        GitDiffRunner.BranchOption(
            name: name, worktree: worktree.map { URL(fileURLWithPath: $0) }, isCurrent: current)
    }

    /// Pick a branch through the real open → highlight → commit path, the same one a person uses.
    private func pickHead(_ overlay: DiffViewerOverlay, steps: Int) throws {
        let dropdown = overlay.headDropdownForTesting
        dropdown.openListForTesting()
        dropdown.moveHighlightForTesting(steps)
        window!.makeFirstResponder(dropdown)
        let commit = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36))
        dropdown.keyDown(with: commit)
    }

    func test_headDropdown_leadsWithTheCheckedOutBranch() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main"],
            heads: [Self.head("feature", current: true), Self.head("main", worktree: "/tmp/wt")])

        XCTAssertEqual(overlay.headDropdownForTesting.buttonTitleForTesting, "Branch: feature")
    }

    /// A branch with no worktree can only show committed work, and the reader is told so in the list
    /// rather than discovering it as "my uncommitted changes vanished".
    func test_headDropdown_notesBranchesThatCanOnlyShowCommittedWork() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [
                Self.head("feature", current: true),
                Self.head("has-tree", worktree: "/tmp/wt"),
                Self.head("no-tree"),
            ])

        let items = overlay.headDropdownForTesting.itemsForTesting
        XCTAssertNil(items.first { $0.title == "has-tree" }?.note, "a real working tree needs no caveat")
        XCTAssertEqual(items.first { $0.title == "no-tree" }?.note, "committed only")
    }

    /// The pick reaches the loader as the whole option, because only the host can turn a worktree path
    /// into a runner rooted there.
    func test_pickingABranchWithAWorktree_handsTheOptionToTheLoader() throws {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("other", worktree: "/tmp/wt")])

        try pickHead(overlay, steps: 1)

        XCTAssertEqual(spy.lastHead?.name, "other")
        XCTAssertEqual(spy.lastHead?.worktree, URL(fileURLWithPath: "/tmp/wt"))
    }

    func test_pickingABranchWithAWorktree_retargetsTheHostWatcher() throws {
        var watchedRoots: [URL] = []
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("other", worktree: "/tmp/wt")],
            onRepoRootChange: { watchedRoots.append($0) })

        try pickHead(overlay, steps: 1)

        XCTAssertEqual(watchedRoots, [URL(fileURLWithPath: "/tmp/wt")])
    }

    func test_pickingABranchWithoutAWorktree_stillHandsItOver() throws {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("no-tree")])

        try pickHead(overlay, steps: 1)

        XCTAssertEqual(spy.lastHead?.name, "no-tree")
        XCTAssertNil(spy.lastHead?.worktree, "the host reads this as committed-only")
    }

    /// Picking the checked-out branch clears the override rather than pinning it, so the viewer goes
    /// back to plain "this checkout" and follows it if the reader switches branches underneath.
    func test_pickingBackToTheCheckedOutBranch_clearsTheOverride() throws {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("other", worktree: "/tmp/wt")])

        try pickHead(overlay, steps: 1)
        XCTAssertEqual(spy.lastHead?.name, "other")

        try pickHead(overlay, steps: -1)
        XCTAssertNil(spy.lastHead, "back on the checkout, the viewer stops pinning a branch")
    }

    /// The pickers are stacked, so the arrows step between them vertically. Up off the base picker
    /// reaches the branch one, which was the whole way in for a keyboard user.
    func test_arrowUpFromTheBasePicker_reachesTheBranchPicker() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main"],
            heads: [Self.head("feature", current: true), Self.head("other")])

        window!.makeFirstResponder(overlay.baseDropdownForTesting)
        overlay.baseDropdownForTesting.keyDown(with: keyDown(126))

        XCTAssertTrue(overlay.isHeadDropdownFocusedForTesting)
    }

    /// And back down again, rather than skipping past it into the tree.
    func test_arrowDownFromTheBranchPicker_landsOnTheBasePicker() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main"],
            heads: [Self.head("feature", current: true), Self.head("other")])

        window!.makeFirstResponder(overlay.headDropdownForTesting)
        overlay.headDropdownForTesting.keyDown(with: keyDown(125))

        XCTAssertTrue(overlay.isBaseDropdownFocusedForTesting)
    }

    /// With no base to land on, Down falls through to the tree instead of stranding focus.
    func test_arrowDownFromTheBranchPicker_fallsThroughToTheTreeWhenThereIsNoBase() {
        let (overlay, _) = mount(
            unstaged: [file("U.swift")],  // no committed slice, so no base resolves
            heads: [Self.head("feature", current: true), Self.head("other")])

        window!.makeFirstResponder(overlay.headDropdownForTesting)
        overlay.headDropdownForTesting.keyDown(with: keyDown(125))

        XCTAssertFalse(overlay.isBaseDropdownFocusedForTesting)
        XCTAssertFalse(overlay.isHeadDropdownFocusedForTesting, "focus moved on into the tree")
    }

    /// The branch being compared against is never worth reading, since its diff with itself is empty.
    /// The mirror of the base picker excluding the checked-out branch.
    func test_headDropdown_excludesWhicheverBranchIsTheBase() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [
                Self.head("feature", current: true),
                Self.head("main", worktree: "/tmp/main"),
                Self.head("other"),
            ])

        let titles = overlay.headDropdownForTesting.itemsForTesting.map(\.title)
        XCTAssertFalse(titles.contains("main"), "reading the base against itself is an empty diff")
        XCTAssertEqual(titles, ["feature", "other"])
    }

    // MARK: review findings — the three caught on PR #159

    /// Copilot: the head picker was never hidden, so before `headsLoader` returns (which is every open)
    /// an empty untitled control sat above the base picker inside a header sized for one row, pushing
    /// the base picker under `clipsToBounds`. Both pickers hide independently now and the stack
    /// collapses whichever is gone.
    func test_headPickerHidden_whileTheBranchListIsStillEmpty() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main"], heads: [])  // heads not yet loaded

        XCTAssertFalse(overlay.isHeadDropdownShownForTesting, "no branches to offer, so no empty control")
        XCTAssertTrue(overlay.isBaseDropdownShownForTesting)
        XCTAssertTrue(overlay.isBaseHeaderShownForTesting)
        XCTAssertEqual(
            overlay.baseHeaderHeightForTesting, DiffViewerOverlay.headerHeight(forPickers: 1),
            "one showing picker means a one-row header, not a two-row one with a gap in it")
    }

    /// And the height follows the count rather than a fixed pair, so the base picker is never sized out
    /// of a header it is inside.
    func test_headerHeight_followsHowManyPickersAreShowing() {
        XCTAssertEqual(DiffViewerOverlay.headerHeight(forPickers: 0), 0)
        XCTAssertLessThan(
            DiffViewerOverlay.headerHeight(forPickers: 1),
            DiffViewerOverlay.headerHeight(forPickers: 2),
            "two pickers need more room than one")
    }

    /// Ultrareview: the overlay's repo root was frozen at init, so a picked worktree branch's diff was
    /// highlighted from the *checkout's* file contents. The root has to follow the loader.
    func test_pickingAWorktreeBranch_retargetsTheRootTheHighlighterReads() throws {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("other", worktree: "/tmp/wt")])
        let opened = overlay.repoRootForTesting

        try pickHead(overlay, steps: 1)

        XCTAssertEqual(
            overlay.repoRootForTesting, URL(fileURLWithPath: "/tmp/wt"),
            "blobs must come from the worktree the diff came from")
        XCTAssertNotEqual(overlay.repoRootForTesting, opened)
    }

    /// A branch with no worktree keeps the original root: there the *ref* moves (`FileDiff.headRef`),
    /// not the root, because there is no second checkout to read.
    func test_pickingABranchWithoutAWorktree_leavesTheRootAlone() throws {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("no-tree")])
        let opened = overlay.repoRootForTesting

        try pickHead(overlay, steps: 1)

        XCTAssertEqual(overlay.repoRootForTesting, opened)
    }

    /// Back on the checked-out branch, the root goes back with it.
    func test_returningToTheCheckedOutBranch_restoresTheOpenedRoot() throws {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("other", worktree: "/tmp/wt")])
        let opened = overlay.repoRootForTesting

        try pickHead(overlay, steps: 1)
        try pickHead(overlay, steps: -1)

        XCTAssertEqual(overlay.repoRootForTesting, opened)
    }

    /// Copilot: a branch can vanish between refreshes (deleted, or its worktree moved), and a session
    /// restores an override from a previous open. Left alone, the picker showed one branch while the
    /// loader was asked for another. The override is re-resolved by name against what git just reported.
    func test_anOverrideForAVanishedBranch_isDroppedOnTheNextRefresh() throws {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("gone", worktree: "/tmp/wt")])

        try pickHead(overlay, steps: 1)
        XCTAssertEqual(spy.lastHead?.name, "gone")
        XCTAssertEqual(overlay.repoRootForTesting, URL(fileURLWithPath: "/tmp/wt"))

        // The branch is deleted out from under the viewer; the next refresh no longer reports it.
        spy.heads = [Self.head("feature", current: true)]
        overlay.reloadForTesting()

        XCTAssertEqual(
            overlay.headDropdownForTesting.buttonTitleForTesting, "Branch: feature",
            "the picker falls back to the checkout rather than naming a branch that is gone")
        XCTAssertNotEqual(
            overlay.repoRootForTesting, URL(fileURLWithPath: "/tmp/wt"),
            "and the root comes back off the vanished worktree")
    }

    /// A refresh that returns nothing (a failed listing) must not discard a live selection — that would
    /// silently reset the reader's branch on a transient git hiccup.
    func test_anEmptyRefresh_doesNotDiscardTheSelection() throws {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("feature", current: true), Self.head("other", worktree: "/tmp/wt")])

        try pickHead(overlay, steps: 1)
        spy.heads = []  // listing failed
        overlay.reloadForTesting()

        XCTAssertEqual(
            overlay.repoRootForTesting, URL(fileURLWithPath: "/tmp/wt"),
            "a failed listing is not evidence the branch is gone")
    }

    /// The other half of the symmetry: the base list hides whichever branch is selected as the head.
    /// It follows the *selection*, not the checkout, which is why this moved out of `GitDiffRunner`.
    func test_baseDropdown_excludesTheSelectedBranch() throws {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature", "other"],
            heads: [Self.head("feature", current: true), Self.head("other", worktree: "/tmp/wt")])

        XCTAssertFalse(
            overlay.baseDropdownForTesting.itemsForTesting.map(\.title).contains("feature"),
            "the branch being read is not something to read it against")

        // Point the viewer at `other`; the base list must follow the new selection, not the checkout.
        try pickHead(overlay, steps: 1)

        let titles = overlay.baseDropdownForTesting.itemsForTesting.map(\.title)
        XCTAssertFalse(titles.contains("other"), "the newly selected branch drops out of the bases")
        XCTAssertTrue(titles.contains("feature"), "and the one no longer selected comes back")
    }

    /// The checked-out branch survives the filter even when it is also the base, because it is the
    /// default and the way back to it.
    func test_headDropdown_keepsTheCheckedOutBranchEvenWhenItIsTheBase() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            heads: [Self.head("main", current: true), Self.head("other")])

        XCTAssertEqual(overlay.headDropdownForTesting.itemsForTesting.map(\.title), ["main", "other"])
    }

    /// A long branch name must truncate rather than hold the tree column open. The label itself has to
    /// yield, not just its container, or its intrinsic width still wins (the ZEN-243 rule).
    func test_branchPickers_yieldTheirWidthRatherThanWideningTheColumn() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main"],
            heads: [
                Self.head("feature", current: true),
                Self.head("a-very-long-branch-name-that-would-otherwise-hold-the-column-open"),
            ])

        for dropdown in [overlay.headDropdownForTesting, overlay.baseDropdownForTesting] {
            XCTAssertEqual(
                dropdown.contentCompressionResistancePriority(for: .horizontal), .defaultLow,
                "the picker must yield before the column does")
        }
    }

    /// "Nothing to compare against" and "nothing to look at" are different states. The base picker
    /// hides for the first; the branch picker must survive it, because it is the way out of the second.
    func test_branchPickerSurvivesARepoWithNoResolvedBase() {
        let (overlay, _) = mount(
            unstaged: [file("U.swift")],  // no committed slice, so no base resolves
            heads: [Self.head("feature", current: true), Self.head("other")])

        XCTAssertTrue(overlay.isBaseHeaderShownForTesting, "the header stays for the branch picker")
        XCTAssertFalse(overlay.isBaseDropdownShownForTesting, "but there is no base to offer")
        XCTAssertEqual(overlay.headDropdownForTesting.buttonTitleForTesting, "Branch: feature")
    }

    func test_choosingABranch_reloadsTheDiffAgainstThatBase() {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])
        let callsBefore = spy.calls

        overlay.chooseBaseForTesting("feature-x")

        XCTAssertEqual(spy.lastBase, "feature-x")  // the committed slice re-ran against the picked base
        XCTAssertGreaterThan(spy.calls, callsBefore)
    }

    func test_choosingTheCurrentBase_isANoOp() {
        let (overlay, spy) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])
        let callsBefore = spy.calls

        overlay.chooseBaseForTesting("main")

        XCTAssertEqual(spy.calls, callsBefore)  // same base — no reload
    }

    // MARK: keyboard nav
    //
    // The pane chords are plain method calls (`handleNavChord`, forwarded by WindowController); the
    // tree's own keys (Esc / Up-at-top / Return-to-fold) go through a real `NSEvent` into
    // `NavOutlineView.keyDown`, since `KeyboardFocus.key(for:)` decodes by keyCode and those paths
    // never run in a state-only test — the exact "control looks fine while dead" gap the project guards.

    /// A `keyDown` built the way AppKit delivers one (arrows carry `.function`/`.numericPad`), so the
    /// event isn't a keystroke macOS never sends (ZEN-145).
    private func keyDown(_ keyCode: UInt16) -> NSEvent {
        let isArrow = (123...126).contains(keyCode)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: isArrow ? [.function, .numericPad] : [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    /// A bare-letter `keyDown` (no modifiers) — the panes decode the vim/viewer keys by
    /// `charactersIgnoringModifiers`, not keyCode, so the character is what matters.
    private func bareKey(_ character: String, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
            keyCode: keyCode)!
    }

    func test_navChords_moveFocusBetweenTreeAndDiff() {
        let (overlay, _) = mount(unstaged: [file("One.swift"), file("Two.swift")])

        XCTAssertTrue(overlay.handleNavChord(.navRight))
        XCTAssertTrue(overlay.isDiffFocusedForTesting)
        XCTAssertTrue(overlay.handleNavChord(.navLeft))
        XCTAssertTrue(overlay.isTreeFocusedForTesting)
    }

    func test_jkInTree_stepThroughFilesSkippingHeaders() {
        let (overlay, _) = mount(unstaged: [file("One.swift"), file("Two.swift")])

        XCTAssertEqual(overlay.selectedFilePathForTesting, "One.swift")  // auto-selected first file
        overlay.treeOutlineForTesting.keyDown(with: bareKey("j", keyCode: 38))
        XCTAssertEqual(overlay.selectedFilePathForTesting, "Two.swift")
        overlay.treeOutlineForTesting.keyDown(with: bareKey("k", keyCode: 40))
        XCTAssertEqual(overlay.selectedFilePathForTesting, "One.swift")  // stepped back past the section
    }

    func test_escKeyDownInTree_closesTheViewer() {
        var cancelled = false
        let (overlay, _) = mount(unstaged: [file("One.swift")], onCancel: { cancelled = true })

        overlay.treeOutlineForTesting.keyDown(with: keyDown(53))  // Esc

        XCTAssertTrue(cancelled, "Esc in the tree closes the card rather than deselecting the row")
    }

    func test_upKeyDownAtTopOfTree_focusesTheBaseDropdown() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])
        overlay.handleNavChord(.navLeft)  // focus the tree
        overlay.selectRowForTesting(0)  // the top row

        overlay.treeOutlineForTesting.keyDown(with: keyDown(126))  // Up

        XCTAssertTrue(overlay.isBaseDropdownFocusedForTesting, "Up at the top row steps into the base dropdown")
    }

    func test_returnKeyDownOnADirectory_foldsIt() {
        let (overlay, _) = mount(unstaged: [file("a/One.swift"), file("a/Two.swift")])
        // Rows: Unstaged=0, a=1, One.swift=2, Two.swift=3.
        XCTAssertEqual(overlay.treeRowCountForTesting, 4)
        overlay.selectRowForTesting(1)  // the "a" directory

        overlay.treeOutlineForTesting.keyDown(with: keyDown(36))  // Return

        XCTAssertEqual(overlay.treeRowCountForTesting, 2, "collapsing the directory hides its files")
    }

    func test_lAndHInTree_expandAndCollapseADirectory() {
        let (overlay, _) = mount(unstaged: [file("a/One.swift"), file("a/Two.swift")])
        // Rows: Unstaged=0, a=1, One.swift=2, Two.swift=3.
        XCTAssertEqual(overlay.treeRowCountForTesting, 4)
        overlay.selectRowForTesting(1)  // the "a" directory

        overlay.treeOutlineForTesting.keyDown(with: bareKey("h", keyCode: 4))  // collapse
        XCTAssertEqual(overlay.treeRowCountForTesting, 2, "h collapses the directory")

        overlay.treeOutlineForTesting.keyDown(with: bareKey("l", keyCode: 37))  // expand
        XCTAssertEqual(overlay.treeRowCountForTesting, 4, "l expands it again")
    }

    func test_shiftHInTree_doesNotFold_theFoldKeysAreBare() {
        let (overlay, _) = mount(unstaged: [file("a/One.swift"), file("a/Two.swift")])
        XCTAssertEqual(overlay.treeRowCountForTesting, 4)
        overlay.selectRowForTesting(1)  // the "a" directory, expanded

        overlay.treeOutlineForTesting.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
                context: nil, characters: "H", charactersIgnoringModifiers: "H", isARepeat: false, keyCode: 4)!)

        XCTAssertEqual(overlay.treeRowCountForTesting, 4, "Shift-h must not collapse — fold is a bare key")
    }

    func test_lOnAFileInTree_focusesTheDiff() {
        let (overlay, _) = mount(unstaged: [file("One.swift"), file("Two.swift")])
        XCTAssertTrue(overlay.handleNavChord(.navLeft))  // start in the tree
        overlay.selectRowForTesting(1)  // One.swift (Unstaged=0, One=1, Two=2)

        overlay.treeOutlineForTesting.keyDown(with: bareKey("l", keyCode: 37))

        XCTAssertTrue(overlay.isDiffFocusedForTesting, "l on a file opens it into the diff")
    }

    func test_bInTree_focusesTheBaseSelector() {
        let (overlay, _) = mount(
            committed: [file("C.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "feature-x"])

        overlay.treeOutlineForTesting.keyDown(with: bareKey("b", keyCode: 11))

        XCTAssertTrue(overlay.isBaseDropdownFocusedForTesting, "b focuses the base-ref selector")
    }

    func test_qInTree_closesTheViewer() {
        var cancelled = false
        let (overlay, _) = mount(unstaged: [file("One.swift")], onCancel: { cancelled = true })

        overlay.treeOutlineForTesting.keyDown(with: bareKey("q", keyCode: 12))

        XCTAssertTrue(cancelled, "q closes the viewer")
    }

    private func ctrlKey(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    func test_ctrlJK_inTree_pageTheFileSelection() {
        let (overlay, _) = mount(unstaged: [file("One.swift"), file("Two.swift"), file("Three.swift")])
        // The test window is tall, so half a page is larger than this list — one page lands on the end.
        overlay.treeOutlineForTesting.keyDown(with: ctrlKey(38))  // Ctrl-j
        XCTAssertEqual(overlay.selectedFilePathForTesting, "Three.swift", "Ctrl-j pages down the file list")
        overlay.treeOutlineForTesting.keyDown(with: ctrlKey(40))  // Ctrl-k
        XCTAssertEqual(overlay.selectedFilePathForTesting, "One.swift", "Ctrl-k pages back up")
    }

    func test_questionKey_togglesTheKeySheet() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        let question = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
            context: nil, characters: "?", charactersIgnoringModifiers: "?", isARepeat: false, keyCode: 44)!

        XCTAssertFalse(overlay.isKeySheetShownForTesting)
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: question)
        XCTAssertTrue(overlay.isKeySheetShownForTesting, "? opens the key sheet")
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: question)
        XCTAssertFalse(overlay.isKeySheetShownForTesting, "? again closes it")
    }

    func test_escWhileKeySheetOpen_closesTheSheetNotTheViewer() {
        var cancelled = false
        let (overlay, _) = mount(unstaged: [file("One.swift")], onCancel: { cancelled = true })
        let diff = overlay.diffPaneForTesting.scrollFocusTarget
        diff.keyDown(with: bareKey("?", keyCode: 44))
        XCTAssertTrue(overlay.isKeySheetShownForTesting, "precondition: the sheet is open")

        diff.keyDown(with: keyDown(53))  // Esc into the focused pane

        XCTAssertFalse(overlay.isKeySheetShownForTesting, "Esc closes the sheet")
        XCTAssertFalse(cancelled, "Esc must not close the viewer while the sheet is open")
    }

    func test_keySheetHint_showsInBothFocusLegends() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertTrue(overlay.handleNavChord(.navLeft))  // tree
        XCTAssertTrue(overlay.footerHintCaptionsForTesting.contains("keys"))
        XCTAssertTrue(overlay.handleNavChord(.navRight))  // diff
        XCTAssertTrue(overlay.footerHintCaptionsForTesting.contains("keys"))
    }

    func test_footerLegend_scopesToTheFocusedPane() {
        let (overlay, _) = mount(unstaged: [file("One.swift"), file("Two.swift")])

        XCTAssertTrue(overlay.handleNavChord(.navLeft))  // focus the tree
        let treeCaptions = overlay.footerHintCaptionsForTesting
        XCTAssertTrue(treeCaptions.contains("fold"), "the tree legend shows the fold keys")
        XCTAssertTrue(treeCaptions.contains("base"))
        XCTAssertFalse(treeCaptions.contains("yank"), "diff-only keys stay off the tree legend")

        XCTAssertTrue(overlay.handleNavChord(.navRight))  // focus the diff
        let diffCaptions = overlay.footerHintCaptionsForTesting
        XCTAssertTrue(diffCaptions.contains("yank"), "the diff legend shows the selection keys")
        XCTAssertTrue(diffCaptions.contains("comment"))
        XCTAssertFalse(diffCaptions.contains("fold"), "tree-only keys stay off the diff legend")
    }

    // MARK: sticky place across a changed reload (ZEN-233)

    /// Send a real vim `j` into the diff pane, the way `DiffPaneTable` decodes it (lowercased
    /// `charactersIgnoringModifiers`), so a cursor move is exercised through the actual key path.
    private func pressJInDiff(_ overlay: DiffViewerOverlay) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: event)
    }

    func test_changedReload_keepsAFoldedDirectoryFolded() {
        let (overlay, spy) = mount(unstaged: [file("a/One.swift"), file("a/Two.swift"), file("Top.swift")])
        // Rows: Unstaged=0, a=1, One=2, Two=3, Top=4 (directories sort before files).
        XCTAssertEqual(overlay.treeRowCountForTesting, 5)
        overlay.selectRowForTesting(1)  // the "a" directory
        overlay.treeOutlineForTesting.keyDown(with: keyDown(36))  // Return folds it
        XCTAssertEqual(overlay.treeRowCountForTesting, 3, "precondition: a's files are hidden")

        // A load that adds an unrelated file — a changed status, so the tree rebuilds.
        spy.status = makeStatus(unstaged: [
            file("a/One.swift"), file("a/Two.swift"), file("Top.swift"), file("Zeta.swift"),
        ])
        overlay.reloadForTesting()

        // a is still folded (its two files stay hidden); the new file shows. Expanded, it would be 6.
        XCTAssertEqual(
            overlay.treeRowCountForTesting, 4, "the folded directory must survive the rebuild, still folded")
    }

    func test_changedReload_keepsTheSelectedFileAndItsCursorLine() {
        let (overlay, spy) = mount(unstaged: [file("One.swift"), file("Two.swift")])
        overlay.selectRowForTesting(2)  // Two.swift (Unstaged=0, One=1, Two=2)
        XCTAssertEqual(overlay.selectedFilePathForTesting, "Two.swift")

        overlay.handleNavChord(.navRight)  // focus the diff pane
        pressJInDiff(overlay)  // move the cursor off the first line
        let parkedCursor = overlay.diffPaneForTesting.cursorLine
        XCTAssertNotNil(parkedCursor?.new, "precondition: the cursor is on a real line")

        spy.status = makeStatus(unstaged: [file("One.swift"), file("Two.swift"), file("Three.swift")])
        overlay.reloadForTesting()

        XCTAssertEqual(overlay.selectedFilePathForTesting, "Two.swift", "the open file survives the reload")
        XCTAssertEqual(
            overlay.diffPaneForTesting.cursorLine?.new, parkedCursor?.new,
            "the cursor lands back on the same line, not snapped to the top")
    }

    func test_changedReload_followsAFileThatWasStaged() {
        // The review loop: park on a file, `git add` it in another pane. It moves Unstaged -> Staged —
        // a new tree row, but the same file, so the selection follows it rather than snapping to the top.
        let (overlay, spy) = mount(unstaged: [file("One.swift"), file("Two.swift")])
        overlay.selectRowForTesting(1)  // One.swift
        XCTAssertEqual(overlay.selectedFilePathForTesting, "One.swift")

        spy.status = makeStatus(unstaged: [file("Two.swift")], staged: [file("One.swift")])
        overlay.reloadForTesting()

        XCTAssertEqual(
            overlay.selectedFilePathForTesting, "One.swift",
            "the selection follows the file into the Staged section")
    }

    func test_changedReload_fallsBackToTheFirstFile_whenTheSelectedFileIsGone() {
        let (overlay, spy) = mount(unstaged: [file("One.swift"), file("Two.swift")])
        overlay.selectRowForTesting(2)  // Two.swift
        XCTAssertEqual(overlay.selectedFilePathForTesting, "Two.swift")

        spy.status = makeStatus(unstaged: [file("One.swift")])  // Two.swift is gone
        overlay.reloadForTesting()

        XCTAssertEqual(
            overlay.selectedFilePathForTesting, "One.swift", "a vanished file falls back to the first")
    }

    func test_backgroundRefresh_keepsAnOpenBaseListOpen_whenTheStatusIsUnchanged() {
        let (overlay, spy) = mount(
            committed: [file("One.swift")], base: (branch: "main", sha: "abc1234"),
            branches: ["main", "develop"])
        let dropdown = overlay.baseDropdownForTesting
        dropdown.openListForTesting()
        let callsBeforeRefresh = spy.calls

        overlay.refresh()

        XCTAssertEqual(spy.calls, callsBeforeRefresh + 1, "the watcher seam runs the injected loader")
        XCTAssertTrue(dropdown.isPopoverOpen, "a background no-op must not close a branch list mid-pick")
    }

    func test_backgroundRefresh_isSingleFlight_andCoalescesToOnePendingLoad() {
        let status = makeStatus(unstaged: [file("One.swift")])
        var completions: [(DiffViewerOverlay.StatusResult) -> Void] = []
        var loadCalls = 0
        var branchCalls = 0
        var headCalls = 0
        let session = DiffViewerSession(
            repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo/repo"))
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            session: session,
            loader: { _, _, completion in
                loadCalls += 1
                completions.append(completion)
            },
            branchesLoader: { completion in
                branchCalls += 1
                completion([])
            },
            headsLoader: { completion in
                headCalls += 1
                completion([])
            },
            sendTargets: { [] },
            sender: { _, _, _ in },
            onCancel: {})

        XCTAssertEqual(loadCalls, 1)
        overlay.refresh()
        overlay.refresh()
        overlay.refresh()
        XCTAssertEqual(loadCalls, 1, "events during a load must not stack Git work")

        let first = completions.removeFirst()
        first(.success(status))
        XCTAssertEqual(loadCalls, 2, "the burst becomes one trailing load")
        XCTAssertEqual(branchCalls, 0, "a stale completion does not start branch probes")

        let second = completions.removeFirst()
        second(.success(status))
        XCTAssertEqual(loadCalls, 2)
        XCTAssertEqual(branchCalls, 1)
        XCTAssertEqual(headCalls, 1, "the current result refreshes branch metadata exactly once")
    }

    func test_backgroundRefresh_tracksOnePathFromUnstagedToStagedAndBackToBothScopes() {
        let path = "Probe.txt"
        let (overlay, spy) = mount(
            unstaged: [file(path, scope: .unstaged, addedLine: "new file")])

        spy.status = makeStatus(
            staged: [file(path, scope: .staged, addedLine: "index")])
        overlay.refresh()
        XCTAssertTrue(renderedTexts(overlay).contains("index"), "git add moves the shown file to Staged")

        spy.status = makeStatus(
            unstaged: [file(path, scope: .unstaged, addedLine: "working edit")],
            staged: [file(path, scope: .staged, addedLine: "index")])
        overlay.refresh()
        XCTAssertTrue(
            renderedTexts(overlay).contains("index"),
            "a new Unstaged copy does not pull the selection out of Staged")

        overlay.selectRowForTesting(1)
        XCTAssertTrue(
            renderedTexts(overlay).contains("working edit"),
            "selecting the Unstaged copy renders its own hunk")

        spy.status = makeStatus(
            unstaged: [file(path, scope: .unstaged, addedLine: "burst final")],
            staged: [file(path, scope: .staged, addedLine: "index")])
        overlay.refresh()
        XCTAssertTrue(
            renderedTexts(overlay).contains("burst final"),
            "the selected Unstaged copy follows the latest background refresh")
    }

    func test_changedReload_expandsADirectoryThatFirstAppears() {
        let (overlay, spy) = mount(unstaged: [file("a/One.swift")])
        XCTAssertEqual(overlay.treeRowCountForTesting, 3)  // Unstaged, a, One

        spy.status = makeStatus(unstaged: [file("a/One.swift"), file("b/Two.swift")])
        overlay.reloadForTesting()

        // b is new, so it comes up expanded like any first-seen row: Unstaged, a, One, b, Two.
        XCTAssertEqual(
            overlay.treeRowCountForTesting, 5, "a directory the reload first shows opens, it isn't born folded")
    }

    // MARK: reopen memory (ZEN-233)

    func test_reopen_restoresFoldsSelectionCursorAndBase() {
        let session = DiffViewerSession(repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo/repo"))
        let files = [file("a/One.swift"), file("a/Two.swift"), file("Top.swift")]

        // Overlay A: fold "a", open Top.swift, move the cursor, pick a non-default base, then close.
        let (overlayA, _) = mount(
            unstaged: files, base: (branch: "main", sha: "abc1234"),
            branches: ["main", "develop"], session: session)
        overlayA.selectRowForTesting(1)  // the "a" directory
        overlayA.treeOutlineForTesting.keyDown(with: keyDown(36))  // fold it
        overlayA.selectRowForTesting(2)  // Top.swift (Unstaged=0, a=1, Top=2 while a is folded)
        XCTAssertEqual(overlayA.selectedFilePathForTesting, "Top.swift")
        overlayA.handleNavChord(.navRight)
        pressJInDiff(overlayA)
        let parkedCursor = overlayA.diffPaneForTesting.cursorLine
        overlayA.chooseBaseForTesting("develop")
        overlayA.removeFromSuperview()  // fires the teardown snapshot into the session

        // Overlay B: same session, a fresh load. It must land where A left off.
        let (overlayB, spyB) = mount(
            unstaged: files, base: (branch: "main", sha: "abc1234"),
            branches: ["main", "develop"], session: session)

        XCTAssertEqual(spyB.lastBase, "develop", "the picked base is re-run on reopen")
        XCTAssertEqual(overlayB.selectedFilePathForTesting, "Top.swift", "the open file comes back")
        XCTAssertEqual(
            overlayB.diffPaneForTesting.cursorLine?.new, parkedCursor?.new, "the cursor line comes back")
        // a folded: Unstaged, a, Top = 3. Expanded it would be 5.
        XCTAssertEqual(overlayB.treeRowCountForTesting, 3, "the fold comes back")
    }

    func test_reopen_snapshotsAtCloseStart_notAtAnimationEnd() {
        // `closeModal` defers `removeFromSuperview` into the close spring's completion, so a snapshot
        // taken only on `viewDidMoveToWindow` lands after a fast reopen has already read the session. The
        // place must be captured when the close begins (`animateOut`). Here overlay A is closed via
        // `animateOut` but NOT removed, and overlay B — built while A's card is still animating out —
        // must still see A's place.
        let session = DiffViewerSession(repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo/repo"))
        let files = [file("a/One.swift"), file("a/Two.swift"), file("Top.swift")]

        let (overlayA, _) = mount(unstaged: files, session: session)
        overlayA.selectRowForTesting(1)  // the "a" directory
        overlayA.treeOutlineForTesting.keyDown(with: keyDown(36))  // fold it
        overlayA.selectRowForTesting(2)  // Top.swift
        XCTAssertEqual(overlayA.selectedFilePathForTesting, "Top.swift")
        overlayA.animateOut {}  // close begins — the snapshot must happen now, not on removal

        let (overlayB, _) = mount(unstaged: files, session: session)
        XCTAssertEqual(overlayB.selectedFilePathForTesting, "Top.swift", "reopen sees A's file mid-close")
        XCTAssertEqual(overlayB.treeRowCountForTesting, 3, "reopen sees A's fold mid-close")
    }

    func test_freshRepo_doesNotInheritAnotherReposPlace() {
        // A different repo gets its own session in the app; assert the overlay doesn't restore a place
        // it was never given — a fresh session opens fully expanded on the first file.
        let (overlay, _) = mount(unstaged: [file("a/One.swift"), file("a/Two.swift")])
        XCTAssertEqual(overlay.treeRowCountForTesting, 4, "a fresh open is fully expanded")
        XCTAssertEqual(overlay.selectedFilePathForTesting, "a/One.swift", "and sits on the first file")
    }
}
