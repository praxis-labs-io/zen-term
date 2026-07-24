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
            repoName: "repo",
            // Nonexistent, so the highlighter no-ops and never spawns git.
            repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo"),
            highlightStore: DiffHighlightStore(),
            initialStatus: nil,
            loader: { _, completion in completion(.success(status)) },
            branchesLoader: { completion in completion([]) },
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
        XCTAssertEqual(copied(), "Sources/App/Foo.swift:10-11")
    }

    func test_yankWithNoVisualSelection_takesTheCursorLineAlone() throws {
        let overlay = mount([file()])
        inline(overlay)
        try type("j", into: overlay)  // to "line eleven"
        try type("Y", unshifted: "y", flags: .shift, into: overlay)
        XCTAssertEqual(copied(), "Sources/App/Foo.swift:11", "one line renders without a range")
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
        XCTAssertEqual(copied(), "Sources/App/Foo.swift:10")
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
            background: Theme.current.chrome.background.nsColor, repoName: "repo",
            repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo"),
            highlightStore: DiffHighlightStore(), initialStatus: nil,
            loader: { _, completion in completion(.success(status)) },
            branchesLoader: { completion in completion([]) },
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
