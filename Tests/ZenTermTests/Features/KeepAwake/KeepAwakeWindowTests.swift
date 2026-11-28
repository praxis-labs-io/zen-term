import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class KeepAwakeWindowTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController!
    private var keepAwake: KeepAwake!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        Motion.isReduceMotionEnabled = { true }
        SidebarController.resetLastChoiceForTesting()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        keepAwake = KeepAwake(
            power: FakePowerAssertions(), battery: FakeBatterySource(), clock: FakeKeepAwakeClock(),
            settings: { KeepAwake.Settings(keepsDisplayOn: false, batteryStop: 10, grace: 60) },
            activeCount: { 0 })
        controller = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controller.keepAwake = keepAwake
        controller.mountAndStart()
    }

    override func tearDownWithError() throws {
        keepAwake?.turnOff()
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        SidebarController.resetLastChoiceForTesting()
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private var sidebar: SidebarController { controller.sidebarForTesting }

    func test_theCollapsedSidebarToggle_carriesTheDot_whileAHoldIsOn() {
        controller.handle(.toggleSidebar)
        XCTAssertFalse(sidebar.isDocked, "precondition")
        XCTAssertNil(sidebar.windowToggleForTesting.activityDotForTesting.state)

        keepAwake.start(.turnedOff)
        XCTAssertEqual(sidebar.windowToggleForTesting.activityDotForTesting.state, .live)
        XCTAssertEqual(sidebar.windowToggleForTesting.accessibilityValue() as? String, "Keep Awake on")

        keepAwake.turnOff()
        XCTAssertNil(sidebar.windowToggleForTesting.activityDotForTesting.state)
    }

    func test_theFooterIndicator_opensThePopover_andHidesWithTheToolbarButtonsSetting() throws {
        let indicator = sidebar.footer.keepAwakeIndicator
        XCTAssertFalse(indicator.isHidden)
        XCTAssertTrue(indicator.accessibilityPerformPress())
        XCTAssertEqual(controller.keepAwakeMenuForTesting?.isOpen, true)

        sidebar.setHiddenButtons([.keepAwake])

        XCTAssertTrue(indicator.isHidden)
        XCTAssertFalse(sidebar.footer.paletteButtonForTesting.isHidden, "hiding the cup hid the palette button")
    }

    func test_closingThePopover_handsTheKeyboardBack_andUncoversTheRows() throws {
        let before = controller.window.firstResponder
        let menu = try XCTUnwrap(controller.keepAwakeMenuForTesting)
        menu.togglePopover()
        XCTAssertFalse(controller.window.firstResponder === before, "precondition: the popover took the keyboard")
        XCTAssertTrue(sidebar.view.isHoverCovered, "the rows under the card still take hover")

        menu.togglePopover()

        XCTAssertTrue(controller.window.firstResponder === before, "the pane did not get the keyboard back")
        XCTAssertFalse(sidebar.view.isHoverCovered)
    }

    func test_collapsingTheSidebar_closesThePopover() throws {
        let menu = try XCTUnwrap(controller.keepAwakeMenuForTesting)
        menu.togglePopover()

        controller.handle(.toggleSidebar)

        XCTAssertFalse(menu.isOpen, "the card stayed with nothing under it")
    }
}
