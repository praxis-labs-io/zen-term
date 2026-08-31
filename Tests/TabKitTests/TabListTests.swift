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

    // MARK: move

    func test_move_shiftsOneSlotInEachDirection() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))

        XCTAssertTrue(list.move(TabID(3), by: -1))
        XCTAssertEqual(list.order, [TabID(1), TabID(3), TabID(2)])

        XCTAssertTrue(list.move(TabID(3), by: 1))
        XCTAssertEqual(list.order, [TabID(1), TabID(2), TabID(3)])
    }

    /// The moved tab keeps the selection, so a second press moves the same tab again rather than
    /// grabbing whichever tab landed in that slot. The chord is discrete, like the rest of the tab
    /// family: a held key would fling the tab to the wall.
    func test_move_keepsTheMovedTabActive() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))  // 3 is active

        list.move(TabID(3), by: -1)

        XCTAssertEqual(list.activeID, TabID(3))
        XCTAssertEqual(list.activeIndex, 1)
    }

    /// Moving some *other* tab must not steal the selection, which is what a naive
    /// `activeIndex = target` would do.
    func test_move_leavesTheActiveTabActiveWhenAnotherMoves() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))  // 3 is active

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

    /// A delta past the end clamps to the wall rather than trapping on an out-of-range insert.
    func test_move_clampsAnOversizedDelta() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))

        XCTAssertTrue(list.move(TabID(1), by: 99))

        XCTAssertEqual(list.order, [TabID(2), TabID(3), TabID(1)])
    }

    /// The clamp has to survive a delta that overflows the addition, or the "clamps at both ends"
    /// promise trades a wrong answer for a trap. It takes a non-zero index to reach: `0 + .max`
    /// is fine, and no valid index can push `idx + .min` below `Int.min`.
    func test_move_clampsRatherThanTrappingOnAnOverflowingDelta() {
        var list = TabList(first: TabID(1))
        list.add(TabID(2))
        list.add(TabID(3))
        list.add(TabID(4))
        list.select(TabID(2))  // index 1, so `1 + .max` overflows, and it is not already at a wall

        XCTAssertTrue(list.move(TabID(2), by: .max))

        XCTAssertEqual(list.order, [TabID(1), TabID(3), TabID(4), TabID(2)], "clamped to the wall")
        XCTAssertEqual(list.activeID, TabID(2), "and it is still the tab that moved")
    }
}
