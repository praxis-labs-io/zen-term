import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerModifierFanOutTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var made: [RecordingSurface] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.made.append(surface)
            return surface
        }
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        made = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    func test_aModifierMoveReachesTheSurfacesOfATabSwitchedAway() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        controller.mountAndStart()
        controllers.append(controller)
        let firstTab = made
        XCTAssertFalse(firstTab.isEmpty, "the first tab has to own a surface")

        controller.newTabForTesting()
        XCTAssertGreaterThan(made.count, firstTab.count, "the second tab has to own its own surface")

        let release = try commandUp()
        controller.modifiersDidChange(release)

        for surface in firstTab {
            XCTAssertEqual(
                surface.modifierKeyCodes, [0x37],
                "holding ⌘ through ⌘2 sends the release after the tab switch, so a background tab's "
                    + "panes must still hear it or they keep a stale ⌘")
        }
    }

    private func commandUp() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 0x37))
    }
}
