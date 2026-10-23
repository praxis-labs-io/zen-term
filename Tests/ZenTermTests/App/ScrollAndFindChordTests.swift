import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ScrollAndFindChordTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-chords-\(UUID().uuidString)", isDirectory: true)
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

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.mountAndStart()
        controllers.append(controller)
        return controller
    }

    private func focusedSurface(_ controller: WindowController) throws -> RecordingSurface {
        try XCTUnwrap(controller.focusedScrollTargetForTesting?.surface as? RecordingSurface)
    }

    func test_theFourScrollChordsMoveTheFocusedPanesViewport() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.scrollToTop)
        controller.handle(.scrollToBottom)
        controller.handle(.scrollPageUp)
        controller.handle(.scrollPageDown)

        XCTAssertEqual(surface.scrolls, [.top, .bottom, .pageFraction(-1), .pageFraction(1)])
    }

    func test_aPageIsAWholeScreenAndPageDownGoesTowardNewerOutput() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.scrollPageDown)

        XCTAssertEqual(surface.scrolls, [.pageFraction(1)])
    }

    func test_aScrollChordDoesNotEnterScrollMode() throws {
        let controller = makeWindow()

        controller.handle(.scrollToTop)

        XCTAssertFalse(controller.scrollMode.isActive)
    }

    func test_findSelectionOpensTheBarOnWhatIsSelected() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.selectionText = "needle"

        controller.handle(.searchSelection)

        XCTAssertTrue(controller.search.isActive)
        XCTAssertEqual(surface.searches.last, "needle")
    }

    func test_findSelectionWithNothingSelectedOpensNoBar() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)

        controller.handle(.searchSelection)

        XCTAssertFalse(controller.search.isActive)
        XCTAssertNil(panel.findBarForTesting)
    }

    func test_findSelectionReadsScrollModesOwnSelectionToo() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows[5] = "an error happened"
        controller.handle(.toggleScrollMode)
        controller.scrollMode.land(on: ScrollCell(row: 5, column: 3))
        _ = controller.scrollMode.handle(try keyDown("v"))
        let selected = try XCTUnwrap(controller.scrollMode.selectedText)

        controller.handle(.searchSelection)

        XCTAssertEqual(surface.searches.last, selected)
    }

    func test_findNextAndPreviousStepTheRunningSearch() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.selectionText = "needle"
        controller.handle(.searchSelection)

        controller.handle(.findNext)
        controller.handle(.findPrevious)

        XCTAssertEqual(surface.searchSteps.suffix(2), [.next, .previous])
    }

    func test_findNextWithNoBarUpStepsNothing() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.findNext)

        XCTAssertEqual(surface.searchSteps, [])
    }

    private func keyDown(_ characters: String) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0))
    }
}
