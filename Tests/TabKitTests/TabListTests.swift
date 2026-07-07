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
        list.select(TabID(99))  // absent → no-op
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
        // [1,2,3] active=3(idx2). Close 1 → [2,3], active still 3.
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        XCTAssertTrue(list.close(TabID(1)))
        XCTAssertEqual(list.order, [TabID(2), TabID(3)])
        XCTAssertEqual(list.activeID, TabID(3))
    }

    func test_close_nonActiveRight_leavesActiveUnchanged() {
        // [1,2,3] active=1(idx0). Close 3 (right of active) → [1,2], active still 1.
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        list.select(TabID(1))
        XCTAssertTrue(list.close(TabID(3)))
        XCTAssertEqual(list.order, [TabID(1), TabID(2)])
        XCTAssertEqual(list.activeID, TabID(1))
    }

    func test_close_active_promotesRightNeighbor() {
        // [1,2,3] active=2(idx1). Close 2 → [1,3], active=3 (the right neighbor).
        var list = TabList(first: TabID(1))
        list.add(TabID(2)); list.add(TabID(3))
        list.select(TabID(2))
        XCTAssertTrue(list.close(TabID(2)))
        XCTAssertEqual(list.order, [TabID(1), TabID(3)])
        XCTAssertEqual(list.activeID, TabID(3))
    }

    func test_close_activeRightmost_clampsToNewLast() {
        // [1,2,3] active=3(idx2). Close 3 → [1,2], active=2 (clamped).
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
}
