import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ScreenAndPromptChordTests: WindowTestCase {
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
            .appendingPathComponent("zenterm-screen-\(UUID().uuidString)", isDirectory: true)
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

    func test_theThreeScreenActionsReachTheFocusedPane() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.clearScreen)
        controller.handle(.selectAll)
        controller.handle(.writeScreenFile)

        XCTAssertEqual(surface.clearScreenCount, 1)
        XCTAssertEqual(surface.selectAllCount, 1)
        XCTAssertEqual(surface.writeScreenFileCount, 1)
    }

    func test_theThreeWriteScreenActionsAskForDifferentDispositions() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.writeScreenFile)
        controller.handle(.copyScreenFilePath)
        controller.handle(.openScreenFile)

        XCTAssertEqual(surface.screenFileDispositions, [.paste, .copy, .open])
    }

    func test_thePromptJumpsMoveTheViewportInTheRightDirection() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.jumpToPreviousPrompt)
        controller.handle(.jumpToNextPrompt)

        XCTAssertEqual(surface.scrolls, [.prompt(-1), .prompt(1)])
    }

    func test_scrollToSelectionMovesTheViewport() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.scrollToSelection)

        XCTAssertEqual(surface.scrolls, [.selection])
    }

    func test_aPromptJumpDoesNotEnterScrollMode() throws {
        let controller = makeWindow()

        controller.handle(.jumpToPreviousPrompt)

        XCTAssertFalse(controller.scrollMode.isActive)
    }

    func test_pasteSelectionPutsTheMouseSelectionBackInThePane() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.selectionText = "./bin/check"

        controller.handle(.pasteSelection)

        XCTAssertEqual(surface.pastes, ["./bin/check"])
    }

    func test_pasteSelectionReadsScrollModesOwnSelectionToo() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.rows[5] = "an error happened"
        controller.handle(.toggleScrollMode)
        controller.scrollMode.land(on: ScrollCell(row: 5, column: 3))
        _ = controller.scrollMode.handle(try keyDown("v"))
        let selected = try XCTUnwrap(controller.scrollMode.selectedText)

        controller.handle(.pasteSelection)

        XCTAssertEqual(surface.pastes, [selected])
    }

    func test_pasteSelectionWithNothingSelectedPastesNothing() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.pasteSelection)

        XCTAssertEqual(surface.pastes, [])
    }

    private func keyDown(_ characters: String) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0))
    }
}
