import AppKit
import PaneKit
import XCTest

@testable import ZenTerm

/// ⏎ in the diff pane opens the composer on the current selection, and while it's up the viewer's own
/// keys step aside (ZEN-257). Driven through real `keyDown` / `performKeyEquivalent` for the same
/// reason as the rest of the diff-viewer suite: the wiring between the table, the viewer and the card
/// is the part that can be silently dead.
final class DiffViewerComposerTests: XCTestCase {
    private var window: NSWindow?
    private var originalConfig: GeneralConfig!
    private var board: NSPasteboard!
    private var closes = 0

    private static let targets = [
        DiffSendTarget(id: PaneID(1), label: "pane 1 · claude"),
        DiffSendTarget(id: PaneID(2), label: "pane 2 · zsh"),
    ]

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        board = NSPasteboard(name: NSPasteboard.Name("com.zenterm.tests.\(UUID().uuidString)"))
        closes = 0
    }

    override func tearDown() {
        board.releaseGlobally()
        board = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        window = nil
        super.tearDown()
    }

    // MARK: harness

    private func file(
        path: String = "Sources/App/Foo.swift", changeKind: ChangeKind = .modified
    ) -> FileDiff {
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

    /// A file whose only change is a removal, so the selection has no new-side line numbers — the case
    /// where the removed text has to ride along in the message.
    private func removalOnlyFile() -> FileDiff {
        FileDiff(
            path: "Sources/App/Gone.swift", oldPath: nil, changeKind: .modified,
            hunks: [
                Hunk(
                    header: "@@ -10,2 +10,1 @@", oldStart: 10, newStart: 10,
                    lines: [
                        DiffLine(kind: .context, oldLineNumber: 10, newLineNumber: 10, text: "kept"),
                        DiffLine(kind: .removed, oldLineNumber: 11, newLineNumber: nil, text: "    gone()"),
                    ])
            ])
    }

    private func mount(
        _ files: [FileDiff], targets: [DiffSendTarget] = DiffViewerComposerTests.targets
    ) -> DiffViewerOverlay {
        let status = GitDiffRunner.StatusLoad(
            unstaged: files, staged: [], committed: [],
            baseBranch: nil, baseSHA: nil, currentBranch: "feature")
        let overlay = DiffViewerOverlay(
            background: Theme.current.chrome.background.nsColor,
            session: DiffViewerSession(repoRoot: URL(fileURLWithPath: "/var/empty/zenterm-tests-no-repo")),
            loader: { _, completion in completion(.success(status)) },
            branchesLoader: { completion in completion([]) },
            sendTargets: { targets },
            sender: { _, _, _ in },
            onCancel: { [weak self] in self?.closes += 1 })
        overlay.yankPasteboard = board
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        XCTAssertTrue(overlay.handleNavChord(.navRight))  // the diff pane, not the tree
        // Inline layout (one row per line) via the real bare `\` key the diff pane decodes (ZEN-262).
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\\", charactersIgnoringModifiers: "\\", isARepeat: false,
                keyCode: 42)!)
        return overlay
    }

    private func type(
        _ characters: String, unshifted: String? = nil, flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0, into overlay: DiffViewerOverlay,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters,
                charactersIgnoringModifiers: unshifted ?? characters, isARepeat: false, keyCode: keyCode),
            file: file, line: line)
        overlay.diffPaneForTesting.scrollFocusTarget.keyDown(with: event)
    }

    private func pressReturn(into overlay: DiffViewerOverlay) throws {
        try type("\r", keyCode: 36, into: overlay)
    }

    private func keyEquivalent(
        keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags = []
    ) throws -> Bool {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        return window!.contentView!.performKeyEquivalent(with: event)
    }

    // MARK: opening

    func test_returnOpensTheComposerOnTheCursorLine() throws {
        let overlay = mount([file()])
        try type("j", into: overlay)  // row 2: the first added line, new line 11

        try pressReturn(into: overlay)
        let composer = try XCTUnwrap(overlay.composerForTesting, "⏎ on the diff opens the composer")
        XCTAssertEqual(
            composer.messageForTesting, "@Sources/App/Foo.swift:11",
            "with no visual selection the cursor line is the selection, so there's always something "
                + "to comment on")
    }

    func test_theReferenceCoversTheWholeVisualBlock() throws {
        let overlay = mount([file()])
        try type("j", into: overlay)
        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)

        try pressReturn(into: overlay)
        let composer = try XCTUnwrap(overlay.composerForTesting)
        XCTAssertEqual(composer.messageForTesting, "@Sources/App/Foo.swift:11-12")
    }

    func test_aRemovalOnlySelectionCarriesTheRemovedLines() throws {
        let overlay = mount([removalOnlyFile()])
        try type("G", unshifted: "g", flags: .shift, into: overlay)  // the removed line

        try pressReturn(into: overlay)
        let composer = try XCTUnwrap(overlay.composerForTesting)
        XCTAssertTrue(
            composer.messageForTesting.hasSuffix("\n\nRemoved lines:\n    gone()"),
            "removed text is in no file on disk, so pointing at it isn't enough: \(composer.messageForTesting)")
    }

    func test_theBoxSitsInTheDiffUnderTheSelectionAndPushesTheLinesBelowItDown() throws {
        let overlay = mount([file()])
        let pane = overlay.diffPaneForTesting
        try type("j", into: overlay)  // cursor onto a line row
        let anchor = try XCTUnwrap(pane.selectedRows.max())
        let anchorTopBefore = pane.rowOriginForTesting(anchor)
        let belowTopBefore = pane.rowOriginForTesting(anchor + 1)

        try pressReturn(into: overlay)
        let box = try XCTUnwrap(overlay.composerForTesting)

        XCTAssertTrue(
            box.isDescendant(of: pane), "the box lives in the diff, not over it — no second modal")
        XCTAssertEqual(
            pane.rowOriginForTesting(anchor), anchorTopBefore,
            "the selected line stays put — the box hangs *under* it, so what you're commenting on "
                + "doesn't move")
        XCTAssertEqual(
            pane.rowOriginForTesting(anchor + 1), belowTopBefore + DiffCommentComposer.height,
            "and only the line below it is pushed down, by exactly the room the box took")
    }

    func test_closingTheBoxGivesTheRoomBack() throws {
        let overlay = mount([file()])
        let pane = overlay.diffPaneForTesting
        try type("j", into: overlay)
        let anchor = try XCTUnwrap(pane.selectedRows.max())
        let belowTopBefore = pane.rowOriginForTesting(anchor + 1)

        try pressReturn(into: overlay)
        XCTAssertNotEqual(pane.rowOriginForTesting(anchor + 1), belowTopBefore, "precondition: it moved")

        XCTAssertTrue(try keyEquivalent(keyCode: 53, characters: "\u{1b}"))
        XCTAssertEqual(pane.rowOriginForTesting(anchor + 1), belowTopBefore, "the diff closes back up")
    }

    func test_noTargetsMeansNoComposer() throws {
        // A tab with nowhere to send to has nothing to offer — quieter than a card with an empty
        // dropdown that can't do anything.
        let overlay = mount([file()], targets: [])
        try pressReturn(into: overlay)
        XCTAssertNil(overlay.composerForTesting)
    }

    // MARK: the viewer steps aside

    func test_escapeClosesTheComposerAndLeavesTheViewerUp() throws {
        let overlay = mount([file()])
        try type("V", unshifted: "v", flags: .shift, into: overlay)
        try type("j", into: overlay)
        try pressReturn(into: overlay)
        XCTAssertNotNil(overlay.composerForTesting)

        XCTAssertTrue(try keyEquivalent(keyCode: 53, characters: "\u{1b}"))
        XCTAssertNil(overlay.composerForTesting, "the composer went")
        XCTAssertEqual(closes, 0, "and the viewer stayed — Esc is layered, not a straight close")
        XCTAssertEqual(
            overlay.diffPaneForTesting.selectedRows, IndexSet(1...2),
            "the block you'd lined up survives a cancelled comment")
    }

    func test_commandCDoesNotYankWhileANoteIsBeingTyped() throws {
        let overlay = mount([file()])
        try pressReturn(into: overlay)
        XCTAssertNotNil(overlay.composerForTesting)

        _ = try keyEquivalent(keyCode: 8, characters: "c", flags: .command)
        XCTAssertNil(
            board.string(forType: .string),
            "⌘C belongs to the note's own text while the composer is up, not to the diff behind it")
    }

    func test_navChordsAreInertWhileTheComposerIsUp() throws {
        let overlay = mount([file()])  // mount leaves the diff pane focused
        try pressReturn(into: overlay)  // open the composer
        XCTAssertNotNil(overlay.composerForTesting, "precondition: the composer is up")

        XCTAssertTrue(overlay.handleNavChord(.navLeft), "consumed, not acted on")
        XCTAssertFalse(
            overlay.isTreeFocusedForTesting,
            "moving pane focus under an open comment would leave it pointing at lines it can't see")
    }

    // MARK: the footer says so

    func test_theFooterAdvertisesTheCommentKey() {
        let overlay = mount([file()])
        XCTAssertTrue(
            overlay.footerHintCaptionsForTesting.contains("comment"),
            "an unadvertised key is an undiscoverable one")
    }
}
