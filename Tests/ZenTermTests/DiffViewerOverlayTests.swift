import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the diff viewer, driven through the real outline view in a window. The git
/// work is a fake `loader`, so no repo. State-only assertions would pass while the tree was dead, the
/// failure mode the project's interaction-test rule guards against.
final class DiffViewerOverlayTests: XCTestCase {
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
        init(status: GitDiffRunner.StatusLoad, failure: GitDiffRunner.Failure?, branches: [String]) {
            self.status = status
            self.failure = failure
            self.branches = branches
        }
        func load(_ base: String?, _ completion: (DiffViewerOverlay.StatusResult) -> Void) {
            calls += 1
            lastBase = base
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
        failure: GitDiffRunner.Failure? = nil, onCancel: @escaping () -> Void = {},
        // A shared session mounts overlay B on the state overlay A left behind — the reopen path.
        session: DiffViewerSession? = nil
    ) -> (overlay: DiffViewerOverlay, spy: LoaderSpy) {
        let status = makeStatus(unstaged: unstaged, staged: staged, committed: committed, base: base)
        let spy = LoaderSpy(status: status, failure: failure, branches: branches)
        // A path that doesn't exist, so the syntax highlighter no-ops (these tests exercise layout and
        // selection, not highlighting) and never spawns git. Its last component is the footer's repo
        // name, so it reads `repo`.
        let session =
            session
            ?? DiffViewerSession(repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo/repo"))
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            session: session,
            loader: { base, completion in spy.load(base, completion) },
            branchesLoader: { completion in completion(spy.branches) },
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

    /// The layout-toggle chord (⌘I by default) must actually swap the rendered pane, not just flip a
    /// flag — the "control looks wired but the screen never moved" failure. Driven through the real
    /// `handleNavChord` path WindowController uses; the row count changes because side-by-side pairs
    /// +/- lines while inline lists each, so a stale render would keep the old count.
    func test_toggleLayoutChord_swapsTheRenderedLayoutLive_andBack() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide)
        let sideBySideRows = overlay.diffRowCountForTesting

        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)
        XCTAssertNotEqual(
            overlay.diffRowCountForTesting, sideBySideRows,
            "the pane must re-render in the new layout, not just flip a flag")

        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))
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

    /// While narrow, inline is forced and the ⌘I toggle is disabled: it must not touch the pin. Since a
    /// narrow pane renders inline regardless of the override, a broken guard is only observable on a later
    /// widen — so pin inline while wide (differs from the side-by-side default), narrow, toggle (must
    /// no-op), then widen and confirm the pin survived. Without the guard the narrow toggle would flip the
    /// pin to side-by-side and this final assertion would catch it.
    func test_whileNarrow_layoutToggleIsDisabled_andDoesNotTouchThePin() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))  // pin inline while wide
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)

        resize(overlay, toWidth: 480)
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline, "narrow forces inline")

        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))  // consumed, but a no-op while narrow
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)

        resize(overlay, toWidth: 1200)
        XCTAssertEqual(
            overlay.renderedDiffLayoutForTesting, .inline, "the wide pin must survive a no-op narrow toggle")
    }

    /// A ⌘I pin set while wide governs only the wide state, and survives a narrow→wide round trip: it
    /// returns to the pinned layout, not the config default. (Default is side-by-side; the pin is inline.)
    func test_widePin_survivesNarrowRoundTrip() {
        let (overlay, _) = mount(unstaged: [file("One.swift")])
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide)

        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))  // pins inline while wide
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

    func test_navChords_moveFocusBetweenTreeAndDiff() {
        let (overlay, _) = mount(unstaged: [file("One.swift"), file("Two.swift")])

        XCTAssertTrue(overlay.handleNavChord(.navRight))
        XCTAssertTrue(overlay.isDiffFocusedForTesting)
        XCTAssertTrue(overlay.handleNavChord(.navLeft))
        XCTAssertTrue(overlay.isTreeFocusedForTesting)
    }

    func test_navDownAndUpInTree_stepThroughFilesSkippingHeaders() {
        let (overlay, _) = mount(unstaged: [file("One.swift"), file("Two.swift")])
        overlay.handleNavChord(.navLeft)  // focus the tree

        XCTAssertEqual(overlay.selectedFilePathForTesting, "One.swift")  // auto-selected first file
        overlay.handleNavChord(.navDown)
        XCTAssertEqual(overlay.selectedFilePathForTesting, "Two.swift")
        overlay.handleNavChord(.navUp)
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
        overlay.handleNavChord(.navDown)  // focus tree isn't needed; select second file below instead
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
