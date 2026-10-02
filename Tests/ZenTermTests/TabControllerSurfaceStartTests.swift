import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class TabControllerSurfaceStartTests: WindowTestCase {
    private var controller: TabController?
    private var window: NSWindow?
    private var spawned: [RecordingSurface] = []
    private var starts: [(surface: TerminalSurface, id: SurfaceID)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        window = nil
        spawned = []
        starts = []
        try super.tearDownWithError()
    }

    private func makeController() -> TabController {
        let controller = TabController(
            initialCWD: nil,
            makeSurface: { [weak self] in
                let surface = RecordingSurface()
                self?.spawned.append(surface)
                return surface
            },
            startSurface: { [weak self] surface, id, _ in self?.starts.append((surface, id)) })
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        self.window = window
        return controller
    }

    func test_panesAndDrawersStartThroughTheTabsStart_withTheirOwnSurfaceIDs() {
        let controller = makeController()
        var registered: [SurfaceID] = []
        controller.onSurfacesRegistered = { registered += $0 }

        controller.start()
        controller.view.layoutSubtreeIfNeeded()
        controller.split(.vertical)
        controller.toggleBottomDrawer()
        controller.toggleRightDrawer()

        XCTAssertEqual(starts.count, 4)
        XCTAssertEqual(Set(starts.map(\.id)), Set(registered))
        XCTAssertTrue(spawned.allSatisfy { $0.startCount == 0 }, "nothing may start a surface behind the tab's back")
    }

    func test_aPaneRetriedAfterAFailedStart_goesThroughTheTabsStartAgain() throws {
        let controller = makeController()
        var retry: (() -> Void)?
        controller.onPaneStartFailed = { again, _ in retry = again }
        controller.start()
        let pane = try XCTUnwrap(spawned.first)

        pane.delegate?.surfaceDidFailToStart(pane)
        try XCTUnwrap(retry)()

        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.first?.id, starts.last?.id)
        XCTAssertEqual(pane.startCount, 0)
    }
}
