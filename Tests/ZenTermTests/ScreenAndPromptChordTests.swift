import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The seven actions taken off libghostty, and the seam methods they ride.
///
/// The sister suite to `ScrollAndFindChordTests`, and the failure is the same shape: every one of
/// these worked before, answered by the backend's own keymap under the pane. The moment we unbind
/// libghostty's copy, a chord wired to nothing looks identical to one wired to the wrong pane.
///
/// Three of them ship with no chord at all, so the palette and the Shortcuts card are the only way
/// in. `CommandCatalogTests` and `SettingsKeybindGroupsTests` hold those; this holds what the
/// action does once something fires it.
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

    // MARK: the screen

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

    /// Writing the file and disposing of the path is one backend call, so the three actions differ
    /// only by what they ask for. A copy-paste slip here sends all three down the same branch, and
    /// the pane looks identical for two of them: the file is written either way.
    func test_theThreeWriteScreenActionsAskForDifferentDispositions() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)

        controller.handle(.writeScreenFile)
        controller.handle(.copyScreenFilePath)
        controller.handle(.openScreenFile)

        XCTAssertEqual(surface.screenFileDispositions, [.paste, .copy, .open])
    }

    // MARK: the prompt marks

    /// Negative is up the buffer, toward older output, matching every other scroll the seam takes.
    /// Flip the sign and ⌘↑ walks the wrong way while still looking like it works.
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

    /// libghostty's prompt jump moves the viewport and leaves the keyboard with the shell. Routing
    /// it through scroll mode would leave the pane deaf until Esc, which is the opposite of what a
    /// one-press chord is for.
    func test_aPromptJumpDoesNotEnterScrollMode() throws {
        let controller = makeWindow()

        controller.handle(.jumpToPreviousPrompt)

        XCTAssertFalse(controller.scrollMode.isActive)
    }

    // MARK: paste the selection

    func test_pasteSelectionPutsTheMouseSelectionBackInThePane() throws {
        let controller = makeWindow()
        let surface = try focusedSurface(controller)
        surface.selectionText = "./bin/check"

        controller.handle(.pasteSelection)

        XCTAssertEqual(surface.pastes, ["./bin/check"])
    }

    /// The other selection model: scroll mode's `v` is the chrome's own overlay and the backend
    /// cannot see it, so reading only `copySelection` would leave ⌘⇧V dead over exactly the
    /// selection the keyboard just made.
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

    /// With nothing selected the chord does nothing, rather than pasting the pasteboard. ⌘V is
    /// what pastes the pasteboard, and a ⌘⇧V that quietly became a second one would put a command
    /// nobody chose on the prompt.
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
