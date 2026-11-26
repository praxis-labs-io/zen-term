import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class FindFieldInteractionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-find-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private struct Opened {
        let controller: WindowController
        let surface: RecordingSurface
        let panel: PanelHostView
        let field: FindField
    }

    private func openFind(needle: String = "error", total: Int? = 3) throws -> Opened {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.mountAndStart()
        controllers.append(controller)
        let surface = try XCTUnwrap(controller.focusedScrollTargetForTesting?.surface as? RecordingSurface)
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)
        controller.handle(.toggleSearch)
        let field = try XCTUnwrap(panel.findFieldForTesting)
        if !needle.isEmpty { controller.search.beginNeedleForTesting(needle) }
        if let total {
            controller.search.report(total: total, from: surface)
            controller.search.report(selected: 0, from: surface)
        }
        controller.window.contentView?.layoutSubtreeIfNeeded()
        return Opened(controller: controller, surface: surface, panel: panel, field: field)
    }

    // Hit-tested rather than sent: an inactive window swallows the first click to activate itself.
    private func click(_ view: NSView, in window: NSWindow) throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let contentView = try XCTUnwrap(window.contentView)
        let target = try XCTUnwrap(
            contentView.hitTest(contentView.convert(point, from: nil)), "nothing takes a click there")
        XCTAssertTrue(target.isDescendant(of: view), "the click lands on \(target), not the field's button over it")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
    }

    // Through the app's queue, so `NSApp.currentEvent` is the key the field editor is handling.
    private func press(_ keyCode: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], in window: NSWindow)
        throws
    {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        NSApp.postEvent(event, atStart: true)
        let dequeued = try XCTUnwrap(
            NSApp.nextEvent(matching: .keyDown, until: .distantFuture, inMode: .default, dequeue: true))
        window.sendEvent(dequeued)
    }

    func test_clickingUp_stepsToTheOlderMatch() throws {
        let opened = try openFind()

        try click(opened.field.olderButtonForTesting, in: opened.controller.window)

        XCTAssertEqual(
            opened.surface.searchSteps, [.next, .next],
            "after the newest is selected, the click lands on the field's button and not the header's control under it")
    }

    func test_clickingDown_stepsToTheNewerMatch() throws {
        let opened = try openFind()

        try click(opened.field.newerButtonForTesting, in: opened.controller.window)

        XCTAssertEqual(opened.surface.searchSteps, [.next, .previous])
    }

    func test_theSteppersIgnoreClicksWhileThereIsNothingToStepTo() throws {
        let opened = try openFind(total: 0)

        try click(opened.field.olderButtonForTesting, in: opened.controller.window)
        try click(opened.field.newerButtonForTesting, in: opened.controller.window)

        XCTAssertEqual(opened.surface.searchSteps, [])
        XCTAssertEqual(opened.field.countTextForTesting, "No matches")
    }

    func test_clickingClose_endsTheSearchAndGivesThePaneTheKeys() throws {
        let opened = try openFind()
        let focusesBefore = opened.surface.focusCount

        try click(opened.field.closeButtonForTesting, in: opened.controller.window)

        XCTAssertFalse(opened.controller.search.isActive)
        XCTAssertEqual(opened.surface.endSearchCount, 1)
        XCTAssertEqual(opened.surface.focusCount, focusesBefore + 1)
    }

    func test_returnStepsOlder_andShiftReturnNewer_withTheCaretStaying() throws {
        let opened = try openFind()
        let window = opened.controller.window
        XCTAssertTrue(opened.field.isFieldFirstResponder, "premise: the caret is in the field")

        try press(36, "\r", in: window)
        try press(36, "\r", flags: .shift, in: window)

        XCTAssertEqual(opened.surface.searchSteps, [.next, .next, .previous])
        XCTAssertTrue(opened.field.isFieldFirstResponder, "stepping never takes the caret out of the field")
        XCTAssertFalse(opened.controller.scrollMode.isActive)
    }

    func test_escapeInTheField_closesIt() throws {
        let opened = try openFind()

        try press(53, "\u{1b}", in: opened.controller.window)

        XCTAssertFalse(opened.controller.search.isActive)
        XCTAssertEqual(opened.surface.endSearchCount, 1)
    }

    private func type(_ text: String, in window: NSWindow) throws {
        for character in text { try press(0, String(character), in: window) }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func test_aQueryThatFits_fadesNeitherEdge() throws {
        let opened = try openFind(needle: "")

        try type("error", in: opened.controller.window)

        XCTAssertTrue(opened.field.isFieldFirstResponder, "premise: the keys reached the field")
        XCTAssertEqual(opened.field.fadedQueryEdgesForTesting.start, false)
        XCTAssertEqual(opened.field.fadedQueryEdgesForTesting.end, false)
    }

    func test_typingPastTheFieldsWidth_fadesTheLeadingEdgeTheTextScrolledUnder() throws {
        let opened = try openFind(needle: "")

        try type(String(repeating: "a", count: 80), in: opened.controller.window)

        XCTAssertEqual(opened.field.fadedQueryEdgesForTesting.start, true)
        XCTAssertEqual(
            opened.field.fadedQueryEdgesForTesting.end, false, "the caret sits at the end, so nothing hides there")
    }

    func test_anOverflowingQuery_fadesItsTrailingEdgeOnceFocusLeaves() throws {
        let opened = try openFind(needle: "")
        let window = opened.controller.window
        try type(String(repeating: "a", count: 80), in: window)

        window.makeFirstResponder(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertFalse(opened.field.isFieldFirstResponder, "premise: focus left the field")
        XCTAssertEqual(opened.field.fadedQueryEdgesForTesting.start, false)
        XCTAssertEqual(opened.field.fadedQueryEdgesForTesting.end, true)
    }

    func test_inTheHeader_findTakesTheRowAndTheChip() throws {
        let opened = try openFind()
        let header = try XCTUnwrap(opened.panel.shownHeaderForTesting)

        XCTAssertTrue(opened.field.isFlat)
        XCTAssertEqual(header.chipForTesting, .find)
        XCTAssertFalse(header.showsTitleAndControlsForTesting)
    }

    func test_closingFind_givesTheHeaderBackItsChipTitleAndControls() throws {
        let opened = try openFind()
        let header = try XCTUnwrap(opened.panel.shownHeaderForTesting)

        try click(opened.field.closeButtonForTesting, in: opened.controller.window)

        XCTAssertEqual(header.chipForTesting, header.processForTesting)
        XCTAssertTrue(header.showsTitleAndControlsForTesting)
    }

    func test_aProgramChangeDuringFind_waitsUntilFindClosesToReachTheChip() throws {
        let opened = try openFind()
        let header = try XCTUnwrap(opened.panel.shownHeaderForTesting)
        XCTAssertNotEqual(header.processForTesting, .worktree, "premise: the new process differs")

        header.content.process = .worktree

        XCTAssertEqual(header.chipForTesting, .find)
        try click(opened.field.closeButtonForTesting, in: opened.controller.window)
        XCTAssertEqual(header.chipForTesting, .worktree)
    }

    func test_withHeadersOff_findIsACardOverTheTerminal() throws {
        var config = GeneralConfig.builtIn
        config.paneHeaders = false
        GeneralConfig.setCurrentForTesting(config)

        let opened = try openFind()

        XCTAssertNil(opened.panel.shownHeaderForTesting)
        XCTAssertFalse(opened.field.isFlat)
    }
}
