import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The seven chords taken off libghostty and given ZenTerm actions.
///
/// Every one of them worked before this, answered by the backend's own keymap under the pane. So
/// the failure these guard against is not a dead key: it is a key that stops doing what it used to
/// do the moment we unbind libghostty's copy and our replacement does not reach the surface. A
/// chord wired to nothing looks identical to one wired to the wrong pane.
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
        controller.showAndStart()
        controllers.append(controller)
        return controller
    }

    private func focusedSurface(_ controller: WindowController) throws -> RecordingSurface {
        try XCTUnwrap(controller.focusedScrollTargetForTesting?.surface as? RecordingSurface)
    }

    // MARK: the viewport

    func test_theFourScrollChordsMoveTheFocusedPanesViewport() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.scrollToTop)
        controller.handle(.scrollToBottom)
        controller.handle(.scrollPageUp)
        controller.handle(.scrollPageDown)

        XCTAssertEqual(surface.scrolls, [.top, .bottom, .pageFraction(-1), .pageFraction(1)])
    }

    /// A page is the whole visible grid, and the sign is the seam's: positive scrolls down, toward
    /// newer output. Getting either wrong gives a chord that moves the right distance the wrong way,
    /// or half as far as the key it is named after.
    func test_aPageIsAWholeScreenAndPageDownGoesTowardNewerOutput() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.scrollPageDown)

        XCTAssertEqual(surface.scrolls, [.pageFraction(1)])
    }

    /// Scroll mode is the other way to read back through a buffer, and these are deliberately not
    /// it: one press, no mode, the keyboard left where it was. A chord routed through scroll mode
    /// would leave the pane deaf to the shell until Esc.
    func test_aScrollChordDoesNotEnterScrollMode() throws {
        let controller = makeWindow()

        controller.handle(.scrollToTop)

        XCTAssertFalse(controller.scrollMode.isActive)
    }

    // MARK: find the selection

    func test_findSelectionOpensTheBarOnWhatIsSelected() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.selectionText = "needle"

        controller.handle(.searchSelection)

        XCTAssertTrue(controller.search.isActive)
        XCTAssertEqual(surface.searches.last, "needle")
    }

    /// The whole difference from `toggle_search`, which reads the same selection and opens on an
    /// empty needle when there is none. Collapse the two and ⌘E becomes a second ⌘/, which is a
    /// chord spent on nothing.
    func test_findSelectionWithNothingSelectedOpensNoBar() throws {
        let controller = makeWindow()
        let panel = try XCTUnwrap(controller.focusedPanelForTesting)

        controller.handle(.searchSelection)

        XCTAssertFalse(controller.search.isActive)
        XCTAssertNil(panel.findBarForTesting)
    }

    /// The other selection model: scroll mode's `v` is the chrome's own overlay and the backend
    /// cannot see it, so reading only `copySelection` would leave ⌘E dead over exactly the
    /// selection the keyboard just made.
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

    // MARK: step the matches

    func test_findNextAndPreviousStepTheRunningSearch() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.selectionText = "needle"
        controller.handle(.searchSelection)

        controller.handle(.findNext)
        controller.handle(.findPrevious)

        XCTAssertEqual(surface.searchSteps.suffix(2), [.next, .previous])
    }

    /// With no bar up there is no search to step. Stepping one that does not exist would move the
    /// viewport for no reason a reader could explain.
    ///
    /// The chord is still consumed, which is where this parts company with libghostty: its
    /// `navigate_search` bind is performable, so a declined ⌘G went on to the program. A ZenTerm
    /// chord is ours whether or not the action has anything to do, the same as ⌘T over a window
    /// that cannot open a tab. `docs/config/config` says so where a user would look.
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
