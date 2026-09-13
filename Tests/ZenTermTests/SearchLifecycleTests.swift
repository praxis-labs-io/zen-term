import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

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
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.mountAndStart()
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

    private func focusedSurface(_ controller: WindowController) throws -> RecordingSurface {
        try XCTUnwrap(controller.focusedScrollTargetForTesting?.surface as? RecordingSurface)
    }

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

    func test_theChordSeedsTheBarFromScrollModesOwnSelection() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows[5] = "an error happened"
        controller.handle(.toggleScrollMode)
        controller.scrollMode.land(on: ScrollCell(row: 5, column: 3))
        _ = controller.scrollMode.handle(try keyDown("v"))
        let selected = try XCTUnwrap(controller.scrollMode.selectedText)

        controller.handle(.toggleSearch)

        XCTAssertEqual(surface.searches.last, selected)
    }

    func test_theChordSeedsTheBarFromAMouseSelectionToo() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.selectionText = "needle"

        controller.handle(.toggleSearch)

        XCTAssertEqual(surface.searches.last, "needle")
    }

    func test_aSelectionSpanningRowsSeedsItsFirstLine() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        surface.selectionText = "first line   \nsecond line\n"

        controller.handle(.toggleSearch)

        XCTAssertEqual(surface.searches.last, "first line")
        XCTAssertEqual(try XCTUnwrap(panel.findBarForTesting).needle, "first line")
    }

    func test_theChordOpensEmptyWithNothingSelected() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.toggleSearch)

        XCTAssertTrue(controller.search.isActive)
        XCTAssertEqual(surface.searches, [], "an empty needle is not a search")
    }

    func test_aSeedArrivingOverAnOpenBarReplacesTheNeedle() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleSearch)
        controller.search.typeForTesting("old")

        controller.search.handle(.wanted(needle: "fresh"), from: surface, panel: panel)

        XCTAssertEqual(surface.searches.last, "fresh", "a stale needle under the caret looks broken")
    }

    func test_whileTheFieldIsFocusedTheModeHandlerStandsDown() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleScrollMode)
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

    func test_committingStepsOntoTheFirstMatch() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")

        controller.search.commit()

        XCTAssertEqual(surface.searchSteps, [.next])
    }

    func test_aMatchOnlyInHistoryIsPreviewedWhileTyping() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")

        controller.search.report(total: 3, from: surface)

        XCTAssertEqual(surface.searchSteps, [.next], "one step brings the match into view")
    }

    func test_aMatchAlreadyOnScreenIsNotChasedWhileTyping() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows[5] = "an error happened"
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")

        controller.search.report(total: 3, from: surface)

        XCTAssertEqual(surface.searchSteps, [], "the viewport already holds one")
    }

    func test_theCountClimbingDoesNotStepOncePerReport() throws {
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

    func test_leavingPutsTheViewportBackAtTheBottom() throws {
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

    func test_focusModeTakesTheFindBarDownWithIt() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.splitVertical)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        XCTAssertTrue(controller.search.isEditing, "precondition: the caret is in the field")

        controller.handle(.toggleZoom)

        XCTAssertFalse(controller.search.isEditing, "a bar left editing declines every key")
        XCTAssertFalse(controller.search.isActive)
        XCTAssertNil(panel.findBarForTesting)
    }

    func test_everyWayOutOfScrollModeTakesTheBarWithIt() throws {
        let exits: [(String, (WindowController, ModeHostSpy) throws -> Void)] = [
            ("q", { _, host in _ = try XCTUnwrap(host.modeHandler)(try self.keyDown("q")) }),
            ("i", { _, host in _ = try XCTUnwrap(host.modeHandler)(try self.keyDown("i")) }),
            ("the chord", { controller, _ in controller.handle(.toggleScrollMode) }),
        ]

        for (name, leave) in exits {
            let controller = makeWindow()
            let host = ModeHostSpy()
            controller.keyModeHost = host
            let surface = try focusedSurface(controller)
            let panel = try XCTUnwrap(controller.focusedPanelForTesting)
            controller.handle(.toggleSearch)
            controller.search.beginNeedleForTesting("error")
            controller.search.commit()
            XCTAssertTrue(controller.scrollMode.isActive, "\(name): precondition")

            try leave(controller, host)

            XCTAssertFalse(controller.scrollMode.isActive, "\(name) must leave the mode")
            XCTAssertFalse(controller.search.isActive, "\(name) must end the search")
            XCTAssertNil(panel.findBarForTesting, "\(name) must take the bar down")
            XCTAssertEqual(surface.endSearchCount, 1, "\(name) must stop the engine, exactly once")
            XCTAssertFalse(
                host.isInstalled, "\(name) must give the prompt every key back, n and N included")
        }
    }

    func test_leavingAReaderOwnedScrollModeAlsoTakesTheBarDown() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleScrollMode)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        controller.search.commit()

        _ = try XCTUnwrap(host.modeHandler)(try keyDown("q"))

        XCTAssertFalse(controller.search.isActive)
        XCTAssertNil(panel.findBarForTesting)
        XCTAssertFalse(host.isInstalled)
    }

    func test_theHeaderIsUpBeforeCommitSoCommittingReflowsNothing() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)

        controller.handle(.toggleSearch)

        XCTAssertTrue(panel.isHeaderVisibleForTesting, "the header goes up with the bar")
        XCTAssertEqual(
            panel.headerContentForTesting?.title, "FIND",
            "and names the phase whose keys are actually live")

        controller.search.commit()

        XCTAssertTrue(panel.isHeaderVisibleForTesting, "still up, so the grid never changed height")
        XCTAssertEqual(panel.headerContentForTesting?.title, "SCROLL")
    }

    func test_aReaderOwnedScrollModeKeepsItsHeaderWhenTheBarCloses() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleScrollMode)
        controller.handle(.toggleSearch)

        controller.search.end()

        XCTAssertTrue(controller.scrollMode.isActive)
        XCTAssertEqual(
            panel.headerContentForTesting?.title, "SCROLL",
            "stripping the indicator off a live mode would leave it running unmarked")
    }

    func test_committingOverAnOpenScrollModeStillReassertsTheUnfocusedRender() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        controller.handle(.toggleScrollMode)
        controller.handle(.toggleSearch)
        let before = surface.focusRenders.count

        controller.search.commit()

        XCTAssertGreaterThan(
            surface.focusRenders.count, before, "no push at all means nothing reconciled the render")
        XCTAssertEqual(surface.focusRenders.last, false)
    }

    func test_escapeHandsTheKeyboardBackToThePane() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        controller.handle(.toggleSearch)
        let before = surface.focusCount

        controller.search.end()

        XCTAssertEqual(surface.focusCount, before + 1)
    }

    func test_committingBeforeThePreviewsAnswerArrivesDoesNotStepTwice() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.beginNeedleForTesting("error")
        controller.search.report(total: 3, from: surface)
        XCTAssertEqual(surface.searchSteps, [.next], "the preview asked for a match")

        controller.search.commit()

        XCTAssertEqual(surface.searchSteps, [.next], "committing must not ask for another")
    }

    func test_typingPastTheDebounceLeavesNothingPendingBehindIt() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.typeForTesting("l")
        controller.search.typeForTesting("line")
        XCTAssertEqual(surface.searches, ["line"], "precondition: one send, the immediate one")
        controller.search.report(total: 3, from: surface)
        controller.search.report(selected: 0, from: surface)
        XCTAssertEqual(surface.searchSteps, [.next], "the preview stepped onto match 0")

        controller.search.commit()

        XCTAssertEqual(surface.searches, ["line"], "committing must not re-send the needle")
        XCTAssertEqual(surface.searchSteps, [.next], "nor step past the match already selected")
    }

    func test_aDebounceThatFiresOnItsOwnLeavesNothingPendingBehindIt() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.typeForTesting("ls")

        let sent = expectation(description: "the debounce fires on its own")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { sent.fulfill() }
        wait(for: [sent], timeout: 2)
        XCTAssertEqual(surface.searches, ["ls"], "precondition: the timer sent it")

        controller.search.report(total: 3, from: surface)
        controller.search.report(selected: 0, from: surface)
        XCTAssertEqual(surface.searchSteps, [.next], "the preview stepped onto match 0")

        controller.search.commit()

        XCTAssertEqual(surface.searches, ["ls"], "committing must not re-send it")
        XCTAssertEqual(surface.searchSteps, [.next], "nor step past the match already selected")
    }

    func test_committingSendsAShortNeedleBeforeSteppingIt() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        controller.handle(.toggleSearch)
        controller.search.typeForTesting("ls")
        XCTAssertEqual(surface.searches, [], "precondition: the debounce is holding it")

        controller.search.commit()

        XCTAssertEqual(surface.searches, ["ls"], "the needle goes down first")
        XCTAssertEqual(surface.searchSteps, [.next], "and only then does it step")
    }

    func test_endingTheSearchTearsDownOnlyOnce() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.echoesEndSearch = true
        controller.handle(.toggleSearch)
        var closures = 0
        let previous = controller.search.onActiveChanged
        controller.search.onActiveChanged = { active in
            if !active { closures += 1 }
            previous?(active)
        }

        controller.search.end()

        XCTAssertEqual(closures, 1, "the re-entrant pass must not run the teardown again")
        XCTAssertEqual(surface.scrolls, [], "nor scroll a second time")
    }

    func test_theScrollChordDuringTypingCommitsRatherThanStartingADeadMode() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleSearch)

        controller.handle(.toggleScrollMode)

        XCTAssertFalse(controller.search.isEditing, "the chord commits")
        XCTAssertTrue(controller.scrollMode.isActive)
        let handler = try XCTUnwrap(host.modeHandler)
        XCTAssertTrue(handler(try keyDown("j")), "and the mode it left up actually takes keys")
    }

    func test_escapeGivesASelectionBackBeforeItClosesTheBar() throws {
        let controller = makeWindow()
        let host = ModeHostSpy()
        controller.keyModeHost = host
        controller.handle(.toggleSearch)
        controller.search.commit()
        let handler = try XCTUnwrap(host.modeHandler)
        _ = handler(try keyDown("v"))
        XCTAssertNotNil(controller.scrollMode.selection, "precondition")

        _ = handler(try keyDown("\u{1b}", keyCode: 53))

        XCTAssertNil(controller.scrollMode.selection, "the selection goes")
        XCTAssertTrue(controller.search.isActive, "the bar stays")
    }

    func test_theViewportGoesBackWhereTheReaderHadItNotToTheBottom() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows = Array(repeating: "", count: 24)
        controller.handle(.toggleSearch)
        controller.search.report(
            position: TerminalScrollPosition(total: 5000, offset: 500, viewport: 24), from: surface)
        controller.search.typeForTesting("error")
        controller.search.report(total: 3, from: surface)
        controller.search.report(
            position: TerminalScrollPosition(total: 5000, offset: 120, viewport: 24), from: surface)

        controller.search.end()

        XCTAssertEqual(surface.scrolls, [.lines(380)], "back by exactly what the search moved")
    }

    func test_everyRetractionTakesTheBarDownAndStopsTheEngine() throws {
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
        XCTAssertEqual(bar.countTextForTesting, "15 / 17", "zero-based, and newest-first")
    }

    func test_theCountReadsInBufferOrderNotTheBackendsWalkOrder() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleSearch)
        let bar = try XCTUnwrap(panel.findBarForTesting)
        controller.search.beginNeedleForTesting("error")
        controller.search.report(total: 3, from: surface)
        controller.search.commit()

        controller.search.report(selected: 0, from: surface)
        XCTAssertEqual(bar.countTextForTesting, "3 / 3", "the newest match is the last one down")

        controller.search.report(selected: 2, from: surface)
        XCTAssertEqual(bar.countTextForTesting, "1 / 3", "the oldest is the one nearest the top")
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
