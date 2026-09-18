import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class PaneCornerRadiusTests: WindowTestCase {
    private var originalConfig: GeneralConfig!
    private var controller: TabController?

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
    }

    override func tearDown() {
        controller?.shutdown()
        controller = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private func apply(gutter: CGFloat, windowChrome: Bool) {
        var config = GeneralConfig.builtIn
        config.windowGutter = gutter
        config.windowChrome = windowChrome
        GeneralConfig.setCurrentForTesting(config)
    }

    func test_radius_keepsItsOwnValueWhenWindowChromeHoldsThePanesClear() {
        apply(gutter: 0, windowChrome: true)
        XCTAssertEqual(
            PanelHostView.cornerRadius, 12,
            "window chrome keeps the top corners 28pt clear of the window, so nothing is concentric")

        apply(gutter: 64, windowChrome: true)
        XCTAssertEqual(PanelHostView.cornerRadius, 12, "the radius must not track the gutter under window chrome")
    }

    func test_radius_isConcentricWithTheWindowWithoutWindowChrome() {
        apply(gutter: 0, windowChrome: false)
        XCTAssertEqual(
            PanelHostView.cornerRadius, WindowCorner.radius, accuracy: 0.01,
            "flush to the window edge, the pane must follow the window's corner")

        apply(gutter: 64, windowChrome: false)
        XCTAssertEqual(
            PanelHostView.cornerRadius, 6, accuracy: 0.01,
            "far from the window corner the radius floors instead of going square")
    }

    func test_liveGutterChange_reroundsAnOpenDrawer() throws {
        apply(gutter: 64, windowChrome: false)
        let controller = TabController(initialCWD: nil, makeSurface: { RecordingSurface() })
        self.controller = controller
        controller.start()
        controller.toggleBottomDrawer()
        let drawer = try XCTUnwrap(controller.bottomDrawerPanelForTesting, "opening the drawer must build its panel")
        XCTAssertEqual(drawer.cornerRadiusForTesting, 6, accuracy: 0.01)

        apply(gutter: 0, windowChrome: false)
        controller.reapplyChromeLayout()

        XCTAssertEqual(
            drawer.cornerRadiusForTesting, WindowCorner.radius, accuracy: 0.01,
            "a live gutter change re-rounded the tiled panes but left the drawer at its old radius")
    }
}
