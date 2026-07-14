import XCTest

@testable import ZenTerm

/// ZEN-55: the LRU budget over never-opened pre-warmed lazygit surfaces.
final class LazygitPrewarmPoolTests: XCTestCase {
    private final class Owner {}

    func test_admitWithinCapacity_evictsNothing() {
        let pool = LazygitPrewarmPool(capacity: 3)
        let owners = [Owner(), Owner(), Owner()]
        var evicted = 0
        for owner in owners { pool.admit(owner) { evicted += 1 } }

        XCTAssertEqual(pool.count, 3)
        XCTAssertEqual(evicted, 0)
        for owner in owners { XCTAssertTrue(pool.contains(owner)) }
    }

    func test_admitPastCapacity_evictsOldestInOrder() {
        let pool = LazygitPrewarmPool(capacity: 2)
        let owners = [Owner(), Owner(), Owner(), Owner()]
        var evictions: [Int] = []
        for (index, owner) in owners.enumerated() {
            pool.admit(owner) { evictions.append(index) }
        }

        XCTAssertEqual(evictions, [0, 1], "oldest entries evict first, in admission order")
        XCTAssertEqual(pool.count, 2)
        XCTAssertFalse(pool.contains(owners[0]))
        XCTAssertFalse(pool.contains(owners[1]))
        XCTAssertTrue(pool.contains(owners[2]))
        XCTAssertTrue(pool.contains(owners[3]))
    }

    func test_remove_freesSlotWithoutEvicting() {
        let pool = LazygitPrewarmPool(capacity: 1)
        let first = Owner()
        let second = Owner()
        var evicted = false
        pool.admit(first) { evicted = true }

        pool.remove(first)
        XCTAssertEqual(pool.count, 0)
        XCTAssertFalse(evicted, "promotion/teardown must never fire the evict closure")

        pool.admit(second) { evicted = true }
        XCTAssertFalse(evicted, "the freed slot absorbs the next admit without eviction")
    }

    func test_removeNonMember_isNoOp() {
        let pool = LazygitPrewarmPool(capacity: 1)
        let member = Owner()
        pool.admit(member) {}
        pool.remove(Owner())
        XCTAssertEqual(pool.count, 1)
        XCTAssertTrue(pool.contains(member))
    }

    func test_reAdmit_refreshesRecency() {
        let pool = LazygitPrewarmPool(capacity: 2)
        let first = Owner()
        let second = Owner()
        let third = Owner()
        var evictedFirst = false
        var evictedSecond = false
        pool.admit(first) { evictedFirst = true }
        pool.admit(second) { evictedSecond = true }

        pool.admit(first) { evictedFirst = true }  // refresh: first is now the newest
        pool.admit(third) {}

        XCTAssertTrue(evictedSecond, "second became the oldest after first's refresh")
        XCTAssertFalse(evictedFirst)
        XCTAssertTrue(pool.contains(first))
    }

    func test_evictClosureReenteringRemove_doesNotCorruptEntries() {
        let pool = LazygitPrewarmPool(capacity: 1)
        let first = Owner()
        let second = Owner()
        // The discard path: an evicted owner's teardown re-enters `remove(self)`.
        pool.admit(first) { pool.remove(first) }
        pool.admit(second) {}

        XCTAssertEqual(pool.count, 1)
        XCTAssertFalse(pool.contains(first))
        XCTAssertTrue(pool.contains(second))
    }
}
