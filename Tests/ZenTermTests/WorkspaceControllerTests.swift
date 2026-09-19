import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class WorkspaceControllerTests: WindowTestCase {
    private var built: [TabController] = []

    override func tearDown() {
        built.forEach { $0.shutdown() }
        built = []
        super.tearDown()
    }

    private func makeWorkspace(firstTab: TabID = TabID(1)) -> WorkspaceController {
        WorkspaceController(
            id: WorkspaceID(raw: 1), configTitle: nil, name: "Home", folder: URL(fileURLWithPath: "/tmp"),
            firstTab: firstTab)
    }

    private func makeController() -> TabController {
        let controller = TabController(initialCWD: nil, makeSurface: { RecordingSurface() })
        built.append(controller)
        return controller
    }

    func test_startsWithItsFirstTabActive() {
        let workspace = makeWorkspace()

        XCTAssertEqual(workspace.tabIDs, [TabID(1)])
        XCTAssertEqual(workspace.activeID, TabID(1))
    }

    func test_addAppendsAndActivates() {
        let workspace = makeWorkspace()

        workspace.add(TabID(2))

        XCTAssertEqual(workspace.tabIDs, [TabID(1), TabID(2)])
        XCTAssertEqual(workspace.activeID, TabID(2))
    }

    func test_setControllerFilesItAndSeedsItsTitle() {
        let workspace = makeWorkspace()
        let controller = makeController()
        controller.pinnedTitle = "editor"

        workspace.setController(controller, for: TabID(1))

        XCTAssertTrue(workspace.controller(TabID(1)) === controller)
        XCTAssertTrue(workspace.activeController === controller)
        XCTAssertEqual(workspace.title(TabID(1)), "editor")
    }

    func test_setControllerOverwritesAReplacedTabInPlace() {
        let workspace = makeWorkspace()
        workspace.setController(makeController(), for: TabID(1))
        let replacement = makeController()
        replacement.pinnedTitle = "worktree"

        workspace.setController(replacement, for: TabID(1))

        XCTAssertEqual(workspace.tabIDs, [TabID(1)])
        XCTAssertTrue(workspace.controller(TabID(1)) === replacement)
        XCTAssertEqual(workspace.title(TabID(1)), "worktree")
    }

    func test_selectMovesTheActiveTab() {
        let workspace = makeWorkspace()
        workspace.add(TabID(2))

        workspace.select(TabID(1))

        XCTAssertEqual(workspace.activeID, TabID(1))
    }

    func test_moveReordersAndKeepsTheActiveTabActive() {
        let workspace = makeWorkspace()
        workspace.add(TabID(2))
        workspace.add(TabID(3))
        workspace.select(TabID(2))

        XCTAssertTrue(workspace.move(TabID(3), by: -2))

        XCTAssertEqual(workspace.tabIDs, [TabID(3), TabID(1), TabID(2)])
        XCTAssertEqual(workspace.activeID, TabID(2))
    }

    func test_closeDropsTheTabAndItsController() {
        let workspace = makeWorkspace()
        workspace.setController(makeController(), for: TabID(1))
        workspace.add(TabID(2))
        workspace.setController(makeController(), for: TabID(2))

        XCTAssertTrue(workspace.close(TabID(2)))

        XCTAssertEqual(workspace.tabIDs, [TabID(1)])
        XCTAssertNil(workspace.controller(TabID(2)))
        XCTAssertNil(workspace.title(TabID(2)))
    }

    func test_closingTheLastTabReportsTheWorkspaceEmpty() {
        let workspace = makeWorkspace()
        workspace.setController(makeController(), for: TabID(1))

        XCTAssertFalse(workspace.close(TabID(1)))

        XCTAssertTrue(workspace.tabIDs.isEmpty)
        XCTAssertNil(workspace.activeID)
        XCTAssertNil(workspace.activeController)
    }

    func test_allSurfacesSpansEveryTab() {
        let workspace = makeWorkspace()
        workspace.setController(makeController(), for: TabID(1))
        workspace.add(TabID(2))
        workspace.setController(makeController(), for: TabID(2))
        workspace.controller(TabID(1))?.start()
        workspace.controller(TabID(2))?.start()

        XCTAssertEqual(workspace.allSurfaces.count, 2)
    }

    func test_shutdownTerminatesEveryTabItHolds() {
        let workspace = makeWorkspace()
        let first = makeController()
        let second = makeController()
        workspace.setController(first, for: TabID(1))
        workspace.add(TabID(2))
        workspace.setController(second, for: TabID(2))
        first.start()
        second.start()
        let surfaces = workspace.allSurfaces.compactMap { $0 as? RecordingSurface }
        XCTAssertEqual(surfaces.count, 2)

        workspace.shutdown()

        XCTAssertTrue(surfaces.allSatisfy(\.terminated))
        XCTAssertNil(workspace.controller(TabID(1)))
        XCTAssertNil(workspace.controller(TabID(2)))
    }
}
