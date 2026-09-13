import XCTest

@testable import TabKit

final class TabListTests: XCTestCase {
    func test_tabIDEquatable() {
        XCTAssertEqual(TabID(1), TabID(1))
        XCTAssertNotEqual(TabID(1), TabID(2))
    }

    func test_init_singleActiveTab() {
        let list = TabList(first: TabID(1))
        XCTAssertEqual(list.order, [TabID(1)])
        XCTAssertEqual(list.activeIndex, 0)
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_add_appendsAndActivates() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
        XCTAssertEqual(list.activeID, TabID(2))
    }

    func test_select_presentAndAbsent() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.select(TabID(1))
        XCTAssertEqual(list.activeID, TabID(1))
        list.select(TabID(99))
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_selectByIndex_clamps() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        list.select(index: 99)
        XCTAssertEqual(list.activeID, TabID(3))
        list.select(index: -5)
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_close_nonActiveLeft_shiftsActiveIndex() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        XCTAssertTrue(list.close(TabID(1)))
        XCTAssertEqual(list.order, [TabID(2), TabID(3)])
        XCTAssertEqual(list.activeID, TabID(3))
    }

    func test_close_nonActiveRight_leavesActiveUnchanged() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        list.select(TabID(1))
        XCTAssertTrue(list.close(TabID(3)))
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_close_active_promotesRightNeighbor() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        list.select(TabID(2))
        XCTAssertTrue(list.close(TabID(2)))
        XCTAssertEqual(list.order, [TabID(1), TabID(3)])
        XCTAssertEqual(list.activeID, TabID(3))
    }

    func test_close_activeRightmost_clampsToNewLast() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        XCTAssertTrue(list.close(TabID(3)))
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
        XCTAssertEqual(list.activeID, TabID(2))
    }

    func test_close_lastTab_returnsFalse() {
        var list = TabList(first: TabID(1))
        XCTAssertFalse(list.close(TabID(1)))
        XCTAssertTrue(list.order.isEmpty)
    }

    func test_close_absent_isNoOpReturnsTrue() {
        var list = TabList(first: TabID(1))
        XCTAssertTrue(list.close(TabID(99)))
        XCTAssertEqual(list.order, [TabID(1)])
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_move_shiftsOneSlotInEachDirection() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))

        XCTAssertTrue(list.move(TabID(3), by: -1))
        XCTAssertEqual(list.order, [TabID(1), TabID(3), TabID(2)])

        XCTAssertTrue(list.move(TabID(3), by: 1))
        XCTAssertEqual(list.order, [TabID(1), TabID(2), TabID(3)])
    }

    func test_move_keepsTheMovedTabActive() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))

        list.move(TabID(3), by: -1)

        XCTAssertEqual(list.activeID, TabID(3))
        XCTAssertEqual(list.activeIndex, 1)
    }

    func test_move_leavesTheActiveTabActiveWhenAnotherMoves() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))

        list.move(TabID(1), by: 1)

        XCTAssertEqual(list.order, [TabID(2), TabID(1), TabID(3)])
        XCTAssertEqual(list.activeID, TabID(3), "the tab that moved was not the active one")
    }

    func test_move_isANoOpAtEitherWall() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))

        XCTAssertFalse(list.move(TabID(1), by: -1), "already leftmost")
        XCTAssertFalse(list.move(TabID(2), by: 1), "already rightmost")
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
    }

    func test_move_isANoOpForASingleTabOrAnAbsentID() {
        var list = TabList(first: TabID(1))
        XCTAssertFalse(list.move(TabID(1), by: 1))

        list.add(TabID(2))
        XCTAssertFalse(list.move(TabID(99), by: 1))
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
    }

    func test_move_clampsAnOversizedDelta() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))

        XCTAssertTrue(list.move(TabID(1), by: 99))

        XCTAssertEqual(list.order, [TabID(2), TabID(3), TabID(1)])
    }

    func test_move_clampsRatherThanTrappingOnAnOverflowingDelta() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))
        list.add(TabID(4))
        list.select(TabID(2))

        XCTAssertTrue(list.move(TabID(2), by: .max))

        XCTAssertEqual(list.order, [TabID(1), TabID(3), TabID(4), TabID(2)], "clamped to the wall")
        XCTAssertEqual(list.activeID, TabID(2), "and it is still the tab that moved")
    }
}
