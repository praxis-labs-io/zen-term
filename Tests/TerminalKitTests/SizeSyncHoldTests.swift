import AppKit
import XCTest

@testable import TerminalKit

final class SizeSyncHoldTests: XCTestCase {
    func test_overlappingHolds_keepTheGridFrozenUntilTheLastReleases() {
        let view = GhosttyHostView()

        view.setSizeSyncSuspended(true)
        view.setSizeSyncSuspended(true)
        XCTAssertTrue(view.isSizeSyncSuspended)

        view.setSizeSyncSuspended(false)
        XCTAssertTrue(
            view.isSizeSyncSuspended,
            "the split-in is still animating this surface — releasing the drawer's hold must not thaw it")

        view.setSizeSyncSuspended(false)
        XCTAssertFalse(view.isSizeSyncSuspended, "the last hold released, so the grid reconciles")
    }

    func test_releaseWithoutAHold_cannotDriveTheCountNegative() {
        let view = GhosttyHostView()

        view.setSizeSyncSuspended(false)
        XCTAssertFalse(view.isSizeSyncSuspended)

        view.setSizeSyncSuspended(true)
        XCTAssertTrue(
            view.isSizeSyncSuspended, "the unmatched release must not have left a debt to pay off")

        view.setSizeSyncSuspended(false)
        XCTAssertFalse(view.isSizeSyncSuspended)
    }
}

final class SizePushCoalescingTests: XCTestCase {
    // Windowless because hosting this view in a real window wants a Metal layer and crashes.
    private func hostedView() -> GhosttyHostView { GhosttyHostView() }

    private func settleRunloop() {
        let turned = expectation(description: "the queued push ran")
        DispatchQueue.main.async { turned.fulfill() }
        wait(for: [turned], timeout: 1)
    }

    func test_aBurstOfFramesInOnePassLandsAsOneGrid() {
        let view = hostedView()

        for width in stride(from: 800, through: 100, by: -50) {
            view.setFrameSize(NSSize(width: CGFloat(width), height: 400))
        }

        XCTAssertEqual(view.sizePushesForTesting, 0, "nothing goes down from inside the pass")

        settleRunloop()

        XCTAssertEqual(view.sizePushesForTesting, 1, "fifteen frames, one grid")
        XCTAssertEqual(
            view.lastPushedFrameForTesting, NSSize(width: 100, height: 400),
            "and it is the frame the pass settled on, not one it passed through")
    }

    func test_aLaterPassPushesAgain() {
        let view = hostedView()

        view.setFrameSize(NSSize(width: 800, height: 400))
        settleRunloop()
        view.setFrameSize(NSSize(width: 600, height: 400))
        settleRunloop()

        XCTAssertEqual(view.sizePushesForTesting, 2)
    }

    func test_aHoldFlushesTheQueuedPushRatherThanDroppingIt() {
        let view = hostedView()

        view.setFrameSize(NSSize(width: 800, height: 400))
        view.setSizeSyncSuspended(true)

        XCTAssertEqual(view.sizePushesForTesting, 1, "the final geometry landed before the freeze")

        settleRunloop()

        XCTAssertEqual(view.sizePushesForTesting, 1, "and the turn does not push it a second time")
    }

    func test_framesDuringAHoldPushNothing() {
        let view = hostedView()
        view.setSizeSyncSuspended(true)

        view.setFrameSize(NSSize(width: 400, height: 400))
        settleRunloop()

        XCTAssertEqual(view.sizePushesForTesting, 0, "the grid is frozen for the animation's length")
    }
}
