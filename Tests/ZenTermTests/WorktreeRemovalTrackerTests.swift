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

    func test_anUnstandardizedPathMatchesTheOneThatBegan() {
        tracker.begin(path)
        let noisy = URL(fileURLWithPath: "/tmp/zenterm-worktrees/app-abc/./feature-x")
        XCTAssertTrue(tracker.isRemoving(noisy))
    }

    func test_oneRemovalDoesNotClaimAnother() {
        tracker.begin(path)
        XCTAssertFalse(tracker.isRemoving(path.deletingLastPathComponent().appendingPathComponent("other")))
    }

    func test_removeClearsTheClaimAndSaysToRelist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try GitFixture.makeRepo(at: root.appendingPathComponent("work", isDirectory: true))
        let treePath = root.appendingPathComponent("wt", isDirectory: true)
        _ = try GitFixture.run(["worktree", "add", "-b", "probe", treePath.path], in: repo)
        let worktree = Worktree(path: treePath, branch: "probe", head: "abc1234", isLocked: false)

        var changes: [String] = []
        tracker.onChanged = { change in
            switch change {
            case .began: changes.append("began")
            case .removed: changes.append("removed")
            case .failed: changes.append("failed")
            }
        }
        var failure: Error?
        let done = expectation(description: "the delete lands")
        tracker.remove(worktree, in: repo) { error in
            failure = error
            done.fulfill()
        }
        XCTAssertTrue(tracker.isRemoving(treePath), "the claim goes in before the picker rebuilds")
        wait(for: [done], timeout: 30)

        XCTAssertNil(failure)
        XCTAssertFalse(tracker.isRemoving(treePath))
        XCTAssertEqual(changes, ["began", "removed"], "removed is what closes the tabs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: treePath.path))
    }

    func test_removeIgnoresAPathAlreadyInFlight() {
        let worktree = Worktree(path: path, branch: "probe", head: "abc1234", isLocked: false)
        tracker.begin(path)
        var changes = 0
        tracker.onChanged = { _ in changes += 1 }

        tracker.remove(worktree, in: path.deletingLastPathComponent()) { _ in
            XCTFail("the second remove must not run")
        }

        XCTAssertEqual(changes, 0, "nothing to announce: the claim was already there")
    }

    func test_whenIdleRunsAtOnceWithNothingInFlight() {
        var ran = false
        tracker.whenIdle { ran = true }
        XCTAssertTrue(ran)
    }

    func test_whenIdleWaitsForTheLastRemoval() {
        let other = path.deletingLastPathComponent().appendingPathComponent("other")
        tracker.begin(path)
        tracker.begin(other)
        var ran = false
        tracker.whenIdle { ran = true }

        tracker.finish(path)
        XCTAssertFalse(ran, "one of two done is not idle")
        tracker.finish(other)
        XCTAssertTrue(ran)
    }

    func test_whenIdleGivesUpAfterItsBudget() {
        tracker.begin(path)
        let ran = expectation(description: "the wait gives up")
        tracker.whenIdle(within: 0.05) { ran.fulfill() }
        wait(for: [ran], timeout: 5)
    }

    func test_whenIdleRunsOnceWhenBothTheFinishAndTheBudgetLand() {
        tracker.begin(path)
        var runs = 0
        tracker.whenIdle(within: 0.05) { runs += 1 }
        tracker.finish(path)
        XCTAssertEqual(runs, 1)

        let settled = expectation(description: "the budget passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(runs, 1)
    }
}
