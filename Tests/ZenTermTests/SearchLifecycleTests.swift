import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The find bar holds an app-global key handler and a live search engine behind it (ZEN-324).
/// Every retraction has to take down both, and the phase-one gate has to give the keyboard away
/// while the field owns it.
///
/// The failures are invisible from the code. A bar left up over a pane you walked away from keeps
/// swallowing keys, a search left running keeps libghostty painting highlights over a bar that is
/// gone, and a phase-one gate that does not stand down makes the field untypeable while looking
/// exactly right.
@MainActor
final class SearchLifecycleTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    private static func spec(_ id: String) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: id, dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: .window,
            toggle: Chord(command: true, shift: true, key: "b"))
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        var config = GeneralConfig.builtIn
        config.floats = [Self.spec("btop")]
        GeneralConfig.setCurrentForTesting(config)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        spawned = []
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.showAndStart()
        controllers.append(controller)
        return controller
    }

    private final class ModeHostSpy: KeyModeHosting {
        var modeHandler: ((NSEvent) -> Bool)?
        var isInstalled: Bool { modeHandler != nil }
    }

    private func keyDown(_ characters: String, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0)
        throws -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
    }

    /// The surface the focused pane is driving, which is the one the bar targets.
    private func focusedSurface(_ controller: WindowController) throws -> RecordingSurface {
        try XCTUnwrap(controller.focusedScrollTargetForTesting?.surface as? RecordingSurface)
    }

    // MARK: opening

    func test_theChordOpensTheBarAndInstallsTheKeyHandler() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        XCTAssertNil(panel.findBarForTesting, "a resting pane shows no find bar")

        controller.handle(.toggleSearch)

        XCTAssertTrue(controller.search.isActive)
        XCTAssertNotNil(panel.findBarForTesting)
        XCTAssertTrue(host.isInstalled, "without the handler installed no bare `n` ever reaches the mode")
    }

    func test_theChordAgainRefocusesRatherThanOpeningASecondBar() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)

        controller.handle(.toggleSearch)
        let first = try XCTUnwrap(panel.findBarForTesting)
        controller.search.commit()
        XCTAssertFalse(controller.search.isEditing)

        controller.handle(.toggleSearch)

        XCTAssertTrue(controller.search.isEditing, "the chord puts the caret back in the field")
        XCTAssertIdentical(panel.findBarForTesting, first, "a second bar would stack on the first")
    }

    // MARK: the phase-one gate

    func test_whileTheFieldIsFocusedTheModeHandlerStandsDown() throws {
        // The interceptor is a local monitor running ahead of the field editor. A mode that keeps
        // claiming keys here eats every character and leaves the bar untypeable, while looking
        // exactly right on screen.
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)  // scroll mode up first: its handler is the one at risk
        controller.handle(.toggleSearch)

        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertFalse(handler(try keyDown("j")), "a bare key must reach the field, not the mode")
        XCTAssertFalse(handler(try keyDown("n")), "including the keys phase two claims")
    }

    func test_afterCommitTheModeHandlerTakesTheKeysBack() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleSearch)
        controller.search.commit()

        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertTrue(handler(try keyDown("n")), "phase two owns n")
        XCTAssertFalse(
            handler(try keyDown("n", flags: .command)),
            "and still declines ⌘N, or the menu item dies while the bar is up")
    }

    // MARK: the engine

    func test_committingStepsOntoTheFirstMatch() throws {
        // libghostty matches eagerly but selects nothing until it is asked, so without this step
        // phase two would open on no match at all.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")

        controller.search.commit()

        XCTAssertEqual(surface.searchSteps, [.next])
    }

    func test_aMatchOnlyInHistoryIsPreviewedWhileTyping() throws {
        // Otherwise the bar counts matches over a screen showing none of them, and Return is
        // pressed on faith.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)  // nothing on screen matches
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")

        controller.search.report(total: 3, from: surface)

        XCTAssertEqual(surface.searchSteps, [.next], "one step brings the match into view")
    }

    func test_aMatchAlreadyOnScreenIsNotChasedWhileTyping() throws {
        // The part of vim's incsearch worth leaving out: stepping here pulls the screen off the
        // answer already in front of the reader.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows[5] = "an error happened"
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")

        controller.search.report(total: 3, from: surface)

        XCTAssertEqual(surface.searchSteps, [], "the viewport already holds one")
    }

    func test_theCountClimbingDoesNotStepOncePerReport() throws {
        // SEARCH_TOTAL fires repeatedly as the engine works back through the buffer.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")

        controller.search.report(total: 1, from: surface)
        controller.search.report(total: 2, from: surface)
        controller.search.report(total: 9, from: surface)

        XCTAssertEqual(surface.searchSteps, [.next], "once per needle, not once per report")
    }

    func test_committingAfterAPreviewStaysOnTheMatchItShowed() throws {
        // A second step here would walk straight past the match the reader is looking at.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        controller.search.report(total: 3, from: surface)
        controller.search.report(selected: 0, from: surface)

        controller.search.commit()

        XCTAssertEqual(surface.searchSteps, [.next], "the preview's step is the only one")
    }

    // MARK: leaving

    func test_leavingPutsTheViewportBackAtTheBottom() throws {
        // A search that scrolled you into history and then closed should not leave you reading
        // something you were only looking for.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        controller.search.report(total: 3, from: surface)
        XCTAssertEqual(surface.scrolls, [], "precondition: the step moved it, not a scroll")

        controller.search.end()

        XCTAssertEqual(surface.scrolls, [.bottom])
    }

    func test_aNeedleThatStopsMatchingGivesTheViewportBack() throws {
        // One character past the last match, the viewport is parked on the previous needle's
        // answer with nothing on screen matching what is now typed.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        controller.search.report(total: 3, from: surface)

        controller.search.beginNeedleForTesting("errorx")
        controller.search.report(total: 0, from: surface)

        XCTAssertEqual(surface.scrolls, [.bottom])
    }

    func test_aSearchThatNeverMovedTheViewportDoesNotScrollOnTheWayOut() throws {
        // The match was on screen the whole time. Scrolling here would move a pane the reader
        // never asked to move.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows[5] = "an error happened"
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        controller.search.report(total: 1, from: surface)

        controller.search.end()

        XCTAssertEqual(surface.scrolls, [])
    }

    func test_aReaderInTheirOwnScrollModeIsLeftWhereTheSearchTookThem() throws {
        // They are still in scroll mode reading, and the match is what they asked to be shown.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleScrollMode)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        controller.search.report(total: 3, from: surface)

        controller.search.end()

        XCTAssertEqual(surface.scrolls, [], "yanking them to the bottom would undo what they found")
        XCTAssertTrue(controller.scrollMode.isActive)
    }

    func test_escapeLeavesTheScrollModeThatCommittingStarted() throws {
        // One keystroke to find something, one to be done with it. Being dropped into a mode you
        // never asked for, needing a second Esc, is the surprise this asserts against.
        let controller = makeWindow()
        controller.handle(.toggleSearch)
        controller.search.commit()
        XCTAssertTrue(controller.scrollMode.isActive, "commit brings it up")

        controller.search.end()

        XCTAssertFalse(controller.scrollMode.isActive)
    }

    func test_aScrollModeTheReaderStartedThemselvesSurvivesTheSearch() throws {
        let controller = makeWindow()
        controller.handle(.toggleScrollMode)
        controller.handle(.toggleSearch)
        controller.search.commit()

        controller.search.end()

        XCTAssertTrue(controller.scrollMode.isActive, "they put themselves there and keep it")
    }

    func test_everyRetractionTakesTheBarDownAndStopsTheEngine() throws {
        // Both halves matter. A bar that vanishes while the engine keeps painting highlights is
        // the bug this asserts against.
        let retractions: [(String, (WindowController) -> Void)] = [
            (
                "a close confirm",
                {
                    $0.presentConfirm(
                        variant: .destructive, title: "Close Pane", message: "Running work will stop.",
                        confirmLabel: "Close", onConfirm: {})
                }
            ),
            ("the window closing", { $0.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }),
            (
                "losing key window",
                {
                    $0.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
                }
            ),
            ("a tool float", { $0.handle(.toggleToolFloat("btop")) }),
            ("a modal card", { $0.handle(.toggleCommandPalette) }),
            ("moving pane focus", { $0.handle(.splitVertical) }),
            ("switching tabs", { $0.handle(.newTab) }),
        ]

        for (name, retract) in retractions {
            let controller = makeWindow()
            let host = ModeHostSpy()
            controller.keyModeHost = host
            let surface = try focusedSurface(controller)
            let panel = try XCTUnwrap(controller.focusedPanelForTesting)
            controller.handle(.toggleSearch)
            XCTAssertTrue(controller.search.isActive, "\(name): precondition")

            retract(controller)

            XCTAssertFalse(controller.search.isActive, "\(name) must end the search")
            XCTAssertNil(panel.findBarForTesting, "\(name) must take the bar down")
            XCTAssertEqual(surface.endSearchCount, 1, "\(name) must stop the engine")
            XCTAssertFalse(host.isInstalled, "\(name) must uninstall the app-global handler")
        }
    }

    func test_theBackendEndingTheSearchClosesTheBarWithoutCallingBack() throws {
        // libghostty owns keybinds of its own that end a search. Calling `endSearch` back at one
        // that has already gone is a loop waiting to happen.
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleSearch)

        controller.search.backendEnded(from: surface)

        XCTAssertFalse(controller.search.isActive)
        XCTAssertNil(panel.findBarForTesting)
        XCTAssertEqual(surface.endSearchCount, 0)
    }

    func test_aReportFromAnotherPaneIsIgnored() throws {
        let controller = makeWindow()
        controller.handle(.splitVertical)
        let other = try XCTUnwrap(spawned.first { $0 !== (try? focusedSurface(controller)) })
        controller.handle(.toggleSearch)

        controller.search.backendEnded(from: other)

        XCTAssertTrue(controller.search.isActive, "a background pane must not close the focused bar")
    }

    // MARK: the count

    func test_theBarShowsATotalWhileTypingAndAnIndexAfterCommit() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleSearch)
        let bar = try XCTUnwrap(panel.findBarForTesting)
        controller.search.beginNeedleForTesting("error")

        controller.search.report(total: 17, from: surface)
        XCTAssertEqual(bar.countTextForTesting, "17 matches")

        controller.search.commit()
        controller.search.report(selected: 2, from: surface)
        XCTAssertEqual(bar.countTextForTesting, "3 / 17", "the backend's index is zero-based")
    }

    func test_noMatchesReadsAsWordsRatherThanAZero() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleSearch)
        let bar = try XCTUnwrap(panel.findBarForTesting)

        controller.search.report(total: 0, from: surface)

        XCTAssertEqual(bar.countTextForTesting, "No matches")
    }
}
