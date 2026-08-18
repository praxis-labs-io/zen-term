import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Reading back through a tool float's own buffer.
/// Every chord here was swallowed over an open card, and a swallowed chord looks exactly like one
/// wired to nothing, so each case drives the real action and asserts it landed on the card's
/// surface rather than on the pane behind it.
@MainActor
final class FloatModeInteractionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        // Reduce Motion completes `animateOut` synchronously, so a dismissed card is out of the
        // view tree by the time an assertion reads it.
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-float-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.mountAndStart()
        c.floatsForTesting.resolveRepoRoot = { $1(GitRepo.repoRoot(for: $0)) }
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func card(_ c: WindowController) throws -> SurfaceFloatOverlay {
        let content = try XCTUnwrap(c.window.contentView)
        return try XCTUnwrap(descendants(of: content).compactMap { $0 as? SurfaceFloatOverlay }.first)
    }

    /// Open Scratch and hand back the shell it spawned. The spawn the toggle caused is the only
    /// handle on it: a Scratch shell and a pane's launch the same way.
    private func openScratch(
        _ c: WindowController, file: StaticString = #filePath, line: UInt = #line
    ) throws -> RecordingSurface {
        let before = spawned.count
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        XCTAssertEqual(
            spawned.count, before + 1, "the open must spawn exactly one shell", file: file, line: line)
        return try XCTUnwrap(spawned.last)
    }

    private func keyDown(_ characters: String) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0))
    }

    /// A fake interceptor, so a test can drive the app-global key handler the mode installs.
    private final class ModeHostSpy: KeyModeHosting {
        var modeHandler: ((NSEvent) -> Bool)?
        var isInstalled: Bool { modeHandler != nil }
    }

    // MARK: scroll mode

    func test_theScrollChordOverAFloat_entersOnTheCard_notThePaneBehind() throws {
        let c = makeWindow()
        let panel = try XCTUnwrap(c.focusedPanelForTesting)
        _ = try openScratch(c)
        let overlay = try card(c)

        c.handle(.toggleScrollMode)

        XCTAssertTrue(c.scrollMode.isActive, "the gate swallowed the chord")
        XCTAssertTrue(overlay.isHeaderVisibleForTesting, "the card wears the mode's header")
        XCTAssertEqual(overlay.headerContentForTesting?.title, "SCROLL")
        XCTAssertFalse(panel.isHeaderVisibleForTesting, "the pane behind is not what is being read")
    }

    func test_scrollKeysOverAFloat_moveTheBandOnTheCardsSurface() throws {
        let c = makeWindow()
        let host = ModeHostSpy()
        c.keyModeHost = host
        _ = try openScratch(c)

        c.handle(.toggleScrollMode)
        let handler = try XCTUnwrap(host.modeHandler, "no handler means no bare key ever reaches the mode")
        let start = c.scrollMode.cursorRow
        XCTAssertTrue(handler(try keyDown("k")))

        XCTAssertEqual(c.scrollMode.cursorRow, start - 1)
        XCTAssertNotNil(try card(c).scrollCursorForTesting.state, "the band has to paint on the card")
    }

    /// The card's surface reports through `ToolFloatController`, which relayed notifications and
    /// nothing else. Unrelayed, the mode sits blind: it never learns where the viewport is.
    func test_aScrollReportFromTheCardsSurface_reachesTheMode() throws {
        let c = makeWindow()
        let surface = try openScratch(c)
        c.handle(.toggleScrollMode)
        let overlay = try card(c)
        XCTAssertEqual(overlay.headerContentForTesting?.title, "SCROLL", "premise: nothing reported yet")

        surface.delegate?.surface(
            surface, scrollPositionDidChange: TerminalScrollPosition(total: 200, offset: 100, viewport: 24))

        XCTAssertEqual(overlay.headerContentForTesting?.title, "SCROLL: 76 BELOW")
    }

    func test_closingTheCardEndsTheMode() throws {
        let c = makeWindow()
        _ = try openScratch(c)
        let overlay = try card(c)
        c.handle(.toggleScrollMode)
        XCTAssertTrue(c.scrollMode.isActive, "premise: the mode is up")

        c.handle(.toggleToolFloat(ToolFloat.scratch.id))

        XCTAssertFalse(c.scrollMode.isActive, "a mode over a card that is gone points at nothing")
        XCTAssertNil(overlay.scrollCursorForTesting.state)
        XCTAssertFalse(overlay.isHeaderVisibleForTesting)
    }

    // MARK: find

    func test_theFindChordOverAFloat_raisesTheBarInTheCard() throws {
        let c = makeWindow()
        let surface = try openScratch(c)
        let overlay = try card(c)
        XCTAssertNil(overlay.findBarForTesting, "premise: a resting card shows no bar")

        c.handle(.toggleSearch)

        let bar = try XCTUnwrap(overlay.findBarForTesting, "the gate swallowed the chord")
        XCTAssertEqual(overlay.headerContentForTesting?.title, "FIND")
        // Mounted is not the same as covering: the bar has to sit above the terminal in the card's
        // own stack, or the grid draws over it.
        let stack = try XCTUnwrap(bar.superview)
        let barIndex = try XCTUnwrap(stack.subviews.firstIndex(of: bar))
        let gridIndex = try XCTUnwrap(stack.subviews.firstIndex(of: surface.view))
        XCTAssertGreaterThan(barIndex, gridIndex)
    }

    func test_theBarSearchesTheCardsSurface_notThePaneBehind() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let float = try openScratch(c)
        float.selectionText = "needle"

        c.handle(.searchSelection)

        XCTAssertEqual(float.searches.last, "needle")
        XCTAssertTrue(pane.searches.isEmpty, "the pane behind the card is not what is being read")
    }

    // MARK: the one-press verbs

    /// The gate's allow-list is a hand-written table, and the switch beside it is exhaustive over
    /// the enum rather than over the list. Every admitted scroll chord is driven here, so a line
    /// dropped from the list fails something instead of passing quietly.
    func test_everyScrollChordInTheGate_movesTheCardsViewport() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let float = try openScratch(c)
        let admitted: [(KeyInterceptor.ReservedChord, TerminalScroll)] = [
            (.scrollToTop, .top), (.scrollToBottom, .bottom),
            (.scrollPageUp, .pageFraction(-1)), (.scrollPageDown, .pageFraction(1)),
            (.scrollToSelection, .selection),
            (.jumpToPreviousPrompt, .prompt(-1)), (.jumpToNextPrompt, .prompt(1)),
        ]

        for (chord, _) in admitted { c.handle(chord) }

        XCTAssertEqual(float.scrolls, admitted.map(\.1))
        XCTAssertTrue(pane.scrolls.isEmpty, "the pane behind the card is not what is being read")
    }

    /// `n` and `N` step a live search, so these two mean nothing without the bar up. They route
    /// through the controller rather than `modeTarget`, and the gate is all that stands between
    /// them and the card.
    func test_theSteppingChordsOverAFloat_walkTheCardsMatches() throws {
        let c = makeWindow()
        let float = try openScratch(c)
        float.selectionText = "hi"
        c.handle(.searchSelection)

        c.handle(.findNext)
        c.handle(.findPrevious)

        XCTAssertEqual(float.searchSteps, [.next, .previous])
    }

    /// The wrong target here is invisible rather than wrong-looking: the text lands in the pane
    /// behind the card, where nothing on screen shows it going astray.
    func test_pasteSelectionOverAFloat_typesBackIntoTheCard() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let float = try openScratch(c)
        float.selectionText = "seq 1 3"

        c.handle(.pasteSelection)

        XCTAssertEqual(float.pastes, ["seq 1 3"])
        XCTAssertTrue(pane.pastes.isEmpty)
    }

    func test_clearScreenOverAFloat_clearsTheCard() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let float = try openScratch(c)

        c.handle(.clearScreen)

        XCTAssertEqual(float.clearScreenCount, 1, "the gate swallowed the chord")
        XCTAssertEqual(pane.clearScreenCount, 0)
    }

    /// All three dispositions, for the same reason the scroll table covers all seven.
    func test_everyScreenFileChordInTheGate_takesTheCardsScreen() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        let float = try openScratch(c)

        c.handle(.writeScreenFile)
        c.handle(.copyScreenFilePath)
        c.handle(.openScreenFile)

        XCTAssertEqual(float.screenFileDispositions, [.paste, .copy, .open])
        XCTAssertEqual(pane.writeScreenFileCount, 0)
    }
}
