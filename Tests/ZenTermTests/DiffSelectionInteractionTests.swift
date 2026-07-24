import AppKit
import XCTest

@testable import ZenTerm

/// The selection layer driven through the real key path in a real window (ZEN-227): every assertion
/// here goes `keyDown` → `DiffTableView` → `DiffPaneTable` → the pasteboard, never by calling the yank
/// or the cursor move directly. A state-only version of these would stay green with the whole key
/// route unwired, which is exactly how a dead control has shipped here before.
final class DiffSelectionInteractionTests: XCTestCase {
    private var window: NSWindow?
    private var originalConfig: GeneralConfig!
    /// A private board, so running the suite never clobbers the developer's clipboard.
    private var board: NSPasteboard!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        board = NSPasteboard(name: NSPasteboard.Name("com.zenterm.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        board.releaseGlobally()
        board = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        window = nil
        super.tearDown()
    }

    // MARK: harness

    /// A file with a clean shape to select over. Inline layout renders one row per line, so the row
    /// indices below are the hunk header (0) then the lines in order (1...).
    private func file(path: String = "Sources/App/Foo.swift", changeKind: ChangeKind = .modified) -> FileDiff {
        FileDiff(
            path: path, oldPath: nil, changeKind: changeKind,
            hunks: [
                Hunk(
                    header: "@@ -10,4 +10,5 @@", oldStart: 10, newStart: 10,
                    lines: [
                        DiffLine(kind: .context, oldLineNumber: 10, newLineNumber: 10, text: "line ten"),
                        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 11, text: "line eleven"),
                        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 12, text: "line twelve"),
                        DiffLine(kind: .context, oldLineNumber: 11, newLineNumber: 13, text: "line thirteen"),
                    ])
            ])
    }

    private func mount(_ files: [FileDiff]) -> DiffViewerOverlay {
        let status = GitDiffRunner.StatusLoad(
            unstaged: files, staged: [], committed: [],
            baseBranch: nil, baseSHA: nil, currentBranch: "feature")
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            // A nonexistent repo root, so the highlighter no-ops and never spawns git.
            session: DiffViewerSession(repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo")),
            loader: { _, completion in completion(.success(status)) },
            branchesLoader: { completion in completion([]) },
            sendTargets: { [] },
            sender: { _, _, _ in },
            onCancel: {})
        overlay.yankPasteboard = board
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        // The diff pane, not the tree, is the surface under test.
        XCTAssertTrue(overlay.handleNavChord(.navRight))
        return overlay
    }

    /// Send a real `keyDown` into the diff pane's key-handling view, the way AppKit would.
    private func type(
        _ characters: String, unshifted: String? = nil, flags: NSEvent.ModifierFlags = [],
        into overlay: DiffViewerOverlay, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters,
                charactersIgnoringModifiers: unshifted ?? characters, isARepeat: false, keyCode: 0),
            file: file, line: line)
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: event)
    }

    /// An arrow, built the way AppKit actually delivers one: `.function` and `.numericPad` are on every
    /// arrow keyDown, and a synthesized event without them is a keystroke macOS never sends (ZEN-145).
    private func arrow(
        down: Bool, shift: Bool = false, into overlay: DiffViewerOverlay,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var flags: NSEvent.ModifierFlags = [.function, .numericPad]
        if shift { flags.insert(.shift) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: down ? 125 : 126),
            file: file, line: line)
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: event)
    }

    private func copied() -> String? { board.string(forType: .string) }

    private func inline(_ overlay: DiffViewerOverlay) {
        // Inline layout is one row per line, so a row index maps to a line without pairing rules.
        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .inline)
    }

    // MARK: selection + yank

    func test_visualThenMoveThenYank_copiesEveryLineInTheBlock() throws {
        let overlay = mount([file()])
        inline(overlay)
        // The pane lands the cursor on the first real line (row 1, "line ten").
        XCTAssertEqual(overlay.diffPaneForTesting.cursorRowForTesting, 1)

        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)
        try type("j", into: overlay)
        XCTAssertEqual(overlay.diffPaneForTesting.selectedRows, IndexSet(1...3), "V then j j spans three rows")

        try type("y", into: overlay)
        XCTAssertEqual(copied(), "line ten\nline eleven\nline twelve")
    }

    func test_yankReference_namesTheNewSideRange() throws {
        let overlay = mount([file()])
        inline(overlay)
        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)
        try type("Y", unshifted: "y", flags: .shift, into: overlay)
        XCTAssertEqual(copied(), "@Sources/App/Foo.swift:10-11")
    }

    func test_yankWithNoVisualSelection_takesTheCursorLineAlone() throws {
        let overlay = mount([file()])
        inline(overlay)
        try type("j", into: overlay)  // to "line eleven"
        try type("Y", unshifted: "y", flags: .shift, into: overlay)
        XCTAssertEqual(copied(), "@Sources/App/Foo.swift:11", "one line renders without a range")
    }

    func test_commandCAndCommandShiftC_yankTheDiffNotTheTerminal() throws {
        let overlay = mount([file()])
        inline(overlay)
        // ⌘C is a main-menu key equivalent for Copy-from-surface; the overlay has to claim it first,
        // and it arrives through `performKeyEquivalent`, not `keyDown`.
        let plain = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(overlay.performKeyEquivalent(with: plain), "the viewer must consume ⌘C")
        XCTAssertEqual(copied(), "line ten")

        let shifted = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: 0, context: nil, characters: "C", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: 8))
        XCTAssertTrue(overlay.performKeyEquivalent(with: shifted))
        XCTAssertEqual(copied(), "@Sources/App/Foo.swift:10")
    }

    // MARK: motions

    func test_shiftArrowExtends_withoutNeedingV() throws {
        let overlay = mount([file()])
        inline(overlay)
        try arrow(down: true, shift: true, into: overlay)
        try arrow(down: true, shift: true, into: overlay)
        XCTAssertEqual(overlay.diffPaneForTesting.selectedRows, IndexSet(1...3))
        XCTAssertTrue(overlay.diffPaneForTesting.hasVisualSelection)
    }

    func test_plainArrowMovesTheCursorWithoutExtending() throws {
        let overlay = mount([file()])
        inline(overlay)
        try arrow(down: true, into: overlay)
        try arrow(down: true, into: overlay)
        XCTAssertEqual(overlay.diffPaneForTesting.selectedRows, IndexSet(integer: 3), "no block, just a cursor")
    }

    func test_extendingUpwardKeepsTheAnchorBelowTheCursor() throws {
        // The case `NSTableView.selectedRow` can't answer: with the selection extended upward, the
        // table's own "selected row" is the anchor, so a cursor read from it would move the wrong end.
        let overlay = mount([file()])
        inline(overlay)
        try type("j", into: overlay)
        try type("j", into: overlay)  // cursor on row 3
        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("k", into: overlay)
        try type("k", into: overlay)
        XCTAssertEqual(overlay.diffPaneForTesting.selectedRows, IndexSet(1...3))
        XCTAssertEqual(overlay.diffPaneForTesting.cursorRowForTesting, 1, "the cursor is the moving end")
    }

    func test_gg_jumpsToTheTop_andASingleGDoesNot() throws {
        let overlay = mount([file()])
        inline(overlay)
        try type("G", unshifted: "g", flags: .shift, into: overlay)
        let bottom = overlay.diffPaneForTesting.cursorRowForTesting
        XCTAssertEqual(bottom, overlay.diffRowCountForTesting - 1, "G lands on the last row")

        try type("g", into: overlay)
        XCTAssertEqual(overlay.diffPaneForTesting.cursorRowForTesting, bottom, "one g only arms")
        try type("g", into: overlay)
        XCTAssertEqual(overlay.diffPaneForTesting.cursorRowForTesting, 0, "the second g fires")
    }

    func test_aKeyBetweenTheTwoGsDisarms() throws {
        let overlay = mount([file()])
        inline(overlay)
        try type("G", unshifted: "g", flags: .shift, into: overlay)
        let bottom = overlay.diffPaneForTesting.cursorRowForTesting
        try type("g", into: overlay)
        try type("k", into: overlay)  // breaks the pair
        try type("g", into: overlay)
        XCTAssertNotEqual(overlay.diffPaneForTesting.cursorRowForTesting, 0, "g k g is not gg")
        XCTAssertEqual(overlay.diffPaneForTesting.cursorRowForTesting, bottom - 1, "the k still moved")
    }

    func test_braceJumpsBetweenChanges() throws {
        let overlay = mount([file()])
        inline(overlay)
        try type("}", unshifted: "]", flags: .shift, into: overlay)
        XCTAssertEqual(overlay.diffPaneForTesting.cursorRowForTesting, 2, "the first added line")
    }

    // MARK: escape

    func test_escapeClearsTheSelectionBeforeItClosesTheViewer() throws {
        var closed = 0
        let status = GitDiffRunner.StatusLoad(
            unstaged: [file()], staged: [], committed: [],
            baseBranch: nil, baseSHA: nil, currentBranch: "feature")
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            session: DiffViewerSession(repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo")),
            loader: { _, completion in completion(.success(status)) },
            branchesLoader: { completion in completion([]) },
            sendTargets: { [] },
            sender: { _, _, _ in },
            onCancel: { closed += 1 })
        overlay.yankPasteboard = board
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        XCTAssertTrue(overlay.handleNavChord(.navRight))

        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)
        XCTAssertTrue(overlay.diffPaneForTesting.hasVisualSelection)

        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                keyCode: 53))
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: escape)
        XCTAssertFalse(overlay.diffPaneForTesting.hasVisualSelection, "the first Esc collapses")
        XCTAssertEqual(closed, 0, "and must not close the viewer out from under the selection")

        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: escape)
        XCTAssertEqual(closed, 1, "the second Esc closes")
    }

    // MARK: surviving a re-render

    /// A file whose two layouts index *differently*: side-by-side pairs each removed line with an added
    /// one, so it has fewer rows than inline, which lists them separately. Required for the layout-flip
    /// test to mean anything — with an add-only file the two layouts happen to line up row for row, and
    /// carrying the cursor by raw index would pass while being wrong.
    private func pairedFile() -> FileDiff {
        FileDiff(
            path: "Sources/App/Paired.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -10,4 +10,4 @@", oldStart: 10, newStart: 10,
                    lines: [
                        DiffLine(kind: .context, oldLineNumber: 10, newLineNumber: 10, text: "line ten"),
                        DiffLine(kind: .removed, oldLineNumber: 11, newLineNumber: nil, text: "was eleven"),
                        DiffLine(kind: .removed, oldLineNumber: 12, newLineNumber: nil, text: "was twelve"),
                        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 11, text: "now eleven"),
                        DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: 12, text: "now twelve"),
                        DiffLine(kind: .context, oldLineNumber: 13, newLineNumber: 13, text: "line thirteen"),
                    ])
            ])
    }

    func test_layoutFlipKeepsTheSelectionAndTheCursorOnTheSameLines() throws {
        // ⌘I (and a resize crossing the auto-fold band) re-renders the same file. Losing the selection
        // there wipes out work mid-review, and because the row *indices* differ between the layouts,
        // carrying the index instead of the line would silently land on a different line.
        let overlay = mount([pairedFile()])
        inline(overlay)
        // Inline rows: 0 header, 1 ctx10, 2 rm11, 3 rm12, 4 add11, 5 add12, 6 ctx13.
        // Side-by-side pairs the removals with the additions: 0 header, 1 ctx, 2 pair11, 3 pair12, 4 ctx.
        try type("j", into: overlay)
        try type("j", into: overlay)
        try type("j", into: overlay)  // cursor on inline row 4, the added line 11
        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)  // extend over added line 12
        try type("Y", unshifted: "y", flags: .shift, into: overlay)
        XCTAssertEqual(copied(), "@Sources/App/Paired.swift:11-12")
        let rowsBefore = overlay.diffPaneForTesting.selectedRows
        XCTAssertEqual(rowsBefore, IndexSet(4...5), "precondition: the inline rows")

        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))
        XCTAssertEqual(overlay.renderedDiffLayoutForTesting, .sideBySide, "precondition: it re-rendered")
        XCTAssertEqual(
            overlay.diffPaneForTesting.selectedRows, IndexSet(2...3),
            "the same *lines*, at the row indices this layout gives them — not the old indices")
        XCTAssertNotEqual(
            overlay.diffPaneForTesting.selectedRows, rowsBefore,
            "precondition: the indices genuinely moved, so carrying the index would be wrong")

        try type("Y", unshifted: "y", flags: .shift, into: overlay)
        XCTAssertEqual(copied(), "@Sources/App/Paired.swift:11-12", "the selection still names the same lines")
    }

    func test_switchingFilesStartsFresh() throws {
        let overlay = mount([file(path: "One.swift"), file(path: "Two.swift")])
        inline(overlay)
        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)
        XCTAssertTrue(overlay.diffPaneForTesting.hasVisualSelection)

        XCTAssertTrue(overlay.handleNavChord(.navLeft))
        XCTAssertTrue(overlay.handleNavChord(.navDown))  // to Two.swift
        XCTAssertEqual(overlay.selectedFilePathForTesting, "Two.swift")
        XCTAssertFalse(
            overlay.diffPaneForTesting.hasVisualSelection, "a different file is not the same review")
    }

    func test_aReRenderDisarmsAHalfTypedGG() throws {
        // `g` arms silently. If the arm survived a re-render, the next single `g` would fire a jump
        // the user never asked for — and there's nothing on screen that would explain it.
        let overlay = mount([file()])
        inline(overlay)
        try type("G", unshifted: "g", flags: .shift, into: overlay)
        let bottom = overlay.diffPaneForTesting.cursorRowForTesting
        try type("g", into: overlay)  // armed

        XCTAssertTrue(overlay.handleNavChord(.toggleDiffLayout))  // re-render
        try type("g", into: overlay)
        XCTAssertNotEqual(
            overlay.diffPaneForTesting.cursorRowForTesting, 0,
            "the arm must not survive the re-render")
        XCTAssertGreaterThan(bottom, 0, "precondition: G had somewhere to go")
    }

    // MARK: yank feedback

    func test_yankFlashesTheYankedLines_andOnlyAfterACopyActuallyLands() throws {
        // A yank leaves nothing on screen, so the flash is the only confirmation it took. Wired to the
        // pasteboard write, not the keystroke: a no-op yank must not flash.
        let overlay = mount([file()])
        inline(overlay)
        XCTAssertFalse(overlay.diffPaneForTesting.isFlashingForTesting, "nothing has been yanked yet")

        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)
        try type("y", into: overlay)
        XCTAssertTrue(overlay.diffPaneForTesting.isFlashingForTesting, "the copy landed, so it flashes")
        XCTAssertEqual(
            overlay.diffPaneForTesting.flashedRowsForTesting, IndexSet(1...2),
            "the flash covers what was yanked, not the whole file")
    }

    // MARK: mouse

    func test_aClickAdoptsTheCursorSoTheNextKeystrokeExtendsFromThere() throws {
        // The mouse path writes the table's selection directly; without adopting it, the next
        // keystroke would snap back to wherever the keyboard cursor had been left.
        let overlay = mount([file()])
        inline(overlay)
        let pane = overlay.diffPaneForTesting
        pane.selectRowsFromMouseForTesting(IndexSet(integer: 3))
        XCTAssertEqual(pane.cursorRowForTesting, 3, "the click's row became the cursor")

        try type("j", into: overlay)
        XCTAssertEqual(pane.selectedRows, IndexSet(integer: 4), "j moved on from the clicked row")
    }

    func test_aShiftClickAboveTheCursorPutsTheCursorAtTheTopEnd() throws {
        // Taking the lower end on faith gets this backwards: extending upward means the mouse landed
        // on the selection's *first* row, so that's the cursor and the row we came from is the anchor.
        // Get it wrong and the next keystroke extends from the wrong end of the block.
        let overlay = mount([file()])
        inline(overlay)
        try type("j", into: overlay)
        try type("j", into: overlay)
        try type("j", into: overlay)  // cursor on row 4
        let pane = overlay.diffPaneForTesting
        pane.selectRowsFromMouseForTesting(IndexSet(1...4))  // shift-click up to row 1
        XCTAssertEqual(pane.cursorRowForTesting, 1, "the mouse landed at the top of the block")

        try type("j", into: overlay)  // shrinks from the top, because that's where the cursor is
        XCTAssertEqual(pane.selectedRows, IndexSet(2...4))
    }

    func test_aShiftClickBelowTheCursorPutsTheCursorAtTheBottomEnd() throws {
        let overlay = mount([file()])
        inline(overlay)
        let pane = overlay.diffPaneForTesting
        XCTAssertEqual(pane.cursorRowForTesting, 1, "precondition: starts at the first line")
        pane.selectRowsFromMouseForTesting(IndexSet(1...4))  // shift-click down to row 4
        XCTAssertEqual(pane.cursorRowForTesting, 4, "the mouse landed at the bottom of the block")

        try type("k", into: overlay)
        XCTAssertEqual(pane.selectedRows, IndexSet(1...3), "shrinks from the bottom")
    }

    func test_aDiscontiguousClickSelectionIsNormalizedImmediately() throws {
        // ⌘-click can leave gaps, but the pane's model is one anchor and one cursor, so the next
        // motion would fill them anyway. Filling them now means the block you see is the block you
        // yank, instead of it quietly growing under the next keystroke.
        let overlay = mount([file()])
        inline(overlay)
        let pane = overlay.diffPaneForTesting
        var gapped = IndexSet(integer: 1)
        gapped.insert(4)
        pane.selectRowsFromMouseForTesting(gapped)
        XCTAssertEqual(pane.selectedRows, IndexSet(1...4), "the gap is closed up front, not on the next key")
    }

    // MARK: the tree

    func test_jAndKMoveTheFileSelectionInTheTree() throws {
        let overlay = mount([file(path: "One.swift"), file(path: "Two.swift")])
        XCTAssertTrue(overlay.handleNavChord(.navLeft))
        XCTAssertEqual(overlay.selectedFilePathForTesting, "One.swift")

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 0))
        overlay.treeOutlineForTesting.keyDown(with: event)
        XCTAssertEqual(overlay.selectedFilePathForTesting, "Two.swift")
    }
}
