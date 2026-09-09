import XCTest

@testable import ZenTerm

final class WorktreeRemovalTrackerTests: XCTestCase {
    private let tracker = WorktreeRemovalTracker()
    private let path = URL(fileURLWithPath: "/tmp/zenterm-worktrees/app-abc/feature-x")

    func test_aPathIsNotRemovingUntilItBegins() {
        XCTAssertFalse(tracker.isRemoving(path))
        tracker.begin(path)
        XCTAssertTrue(tracker.isRemoving(path))
    }

    func test_finishClearsIt() {
        tracker.begin(path)
        tracker.finish(path)
        XCTAssertFalse(tracker.isRemoving(path))
    }

    /// The path reaches this from a `git worktree list` record on one side and a picker row on the
    /// other, so the two spellings of one folder have to agree.
    func test_anUnstandardizedPathMatchesTheOneThatBegan() {
        tracker.begin(path)
        let noisy = URL(fileURLWithPath: "/tmp/zenterm-worktrees/app-abc/./feature-x")
        XCTAssertTrue(tracker.isRemoving(noisy))
    }

    func test_oneRemovalDoesNotClaimAnother() {
        tracker.begin(path)
        XCTAssertFalse(tracker.isRemoving(path.deletingLastPathComponent().appendingPathComponent("other")))
    }
}
