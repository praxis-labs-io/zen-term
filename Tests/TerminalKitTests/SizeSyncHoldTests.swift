import AppKit
import XCTest

@testable import TerminalKit

/// The grid freeze that stops a layout animation reflowing the terminal on every frame is a
/// *count*, not a flag, because its holders overlap: a drawer slide freezes every surface in the
/// tab while a split-in freezes every surface on the canvas, and those sets intersect. Held as a
/// flag, whichever animation landed first thawed panes the other was still animating and the
/// per-frame reflow came back for the rest of that slide. Nothing on screen shows it — the damage
/// is rewrapped scrollback in a full-frame TUI — so this is the silently-dead class that earns a
/// test rather than a runbook line.
///
/// No `start()` here: the view stays pointer-less on purpose, so this covers the hold arithmetic
/// without a Metal layer or a PTY. `syncSizeAndScale` no-ops against a nil surface.
final class SizeSyncHoldTests: XCTestCase {
    func test_overlappingHolds_keepTheGridFrozenUntilTheLastReleases() {
        let view = GhosttyHostView()

        view.setSizeSyncSuspended(true)  // a drawer slide begins
        view.setSizeSyncSuspended(true)  // a split-in begins over it
        XCTAssertTrue(view.isSizeSyncSuspended)

        view.setSizeSyncSuspended(false)  // the drawer lands first
        XCTAssertTrue(
            view.isSizeSyncSuspended,
            "the split-in is still animating this surface — releasing the drawer's hold must not thaw it")

        view.setSizeSyncSuspended(false)  // the split-in lands
        XCTAssertFalse(view.isSizeSyncSuspended, "the last hold released, so the grid reconciles")
    }

    /// A surface created while an animation is already in flight never took that animation's hold,
    /// but still receives its release. That must leave the surface thawed — the safe direction —
    /// rather than driving the count negative, where a later real hold would fail to freeze.
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

/// Auto Layout walks a view through intermediate frames before the one it settles on, and each one
/// reached libghostty, which rewrapped the whole buffer for it. A frame a few pixels wide rewraps
/// the scrollback into a column or two, and libghostty evicts by bytes, so history went and never
/// came back. Nothing on screen says so while it happens: the damage is missing lines afterwards.
final class SizePushCoalescingTests: XCTestCase {
    private func settleRunloop() {
        let turned = expectation(description: "the queued push ran")
        DispatchQueue.main.async { turned.fulfill() }
        wait(for: [turned], timeout: 1)
    }

    func test_aBurstOfFramesInOnePassLandsAsOneGrid() {
        let view = GhosttyHostView()

        for width in stride(from: 800, through: 100, by: -50) {
            view.setFrameSize(NSSize(width: CGFloat(width), height: 400))
        }

        XCTAssertEqual(view.sizePushesForTesting, 0, "nothing goes down from inside the pass")

        settleRunloop()

        XCTAssertEqual(view.sizePushesForTesting, 1, "fifteen frames, one grid: the one it landed on")
    }

    /// A later pass is a later turn, so it gets its own push. Coalescing that would freeze the grid
    /// at whatever the first pass produced, which is a different bug wearing this fix's clothes.
    func test_aLaterPassPushesAgain() {
        let view = GhosttyHostView()

        view.setFrameSize(NSSize(width: 800, height: 400))
        settleRunloop()
        view.setFrameSize(NSSize(width: 600, height: 400))
        settleRunloop()

        XCTAssertEqual(view.sizePushesForTesting, 2)
    }

    /// A hold taken mid-pass has to survive to the queued push, or the freeze the chrome asked for
    /// lands one turn late and the frames it was protecting go down anyway.
    func test_aHoldTakenBeforeTheTurnEndsStopsTheQueuedPush() {
        let view = GhosttyHostView()

        view.setFrameSize(NSSize(width: 800, height: 400))
        view.setSizeSyncSuspended(true)
        settleRunloop()

        XCTAssertEqual(view.sizePushesForTesting, 0, "the hold outranks a push already queued")
    }
}
