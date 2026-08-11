import AppKit
import XCTest

@testable import ZenTerm

/// `WindowTestCase` puts `Motion.isReduceMotionEnabled` back from a teardown hook, and a teardown
/// hook that stops firing fails nothing: every window suite keeps passing while its pin leaks into
/// whatever runs next, which is the leak itself. So the restore gets a test that drives it rather
/// than one that relies on it, the same reason `WindowSweepTests` exists.
final class MotionOverrideRestoreTests: XCTestCase {
    /// Counts reads rather than comparing what the closure returns. A value comparison would pass
    /// with the bug reinstated on a machine that has Reduce Motion switched on, because the
    /// hardcoded `{ NSWorkspace.shared… }` restore this change removed returns `true` there too.
    /// Only the closure the case inherited moves this counter.
    func test_teardownRestoresTheOverrideTheCaseInherited() throws {
        let original = Motion.isReduceMotionEnabled
        defer { Motion.isReduceMotionEnabled = original }

        var inheritedReads = 0
        // Installed before the case is built, because building it is when the capture happens.
        Motion.isReduceMotionEnabled = {
            inheritedReads += 1
            return true
        }
        let windowCase = WindowTestCase()
        Motion.isReduceMotionEnabled = { false }  // stands in for a suite pinning in its setup

        try windowCase.tearDownWithError()

        let before = inheritedReads
        _ = Motion.isReduceMotionEnabled()
        XCTAssertEqual(
            inheritedReads, before + 1,
            "a window case's pin outlived it, so the next suite reads a closure it never set")
    }
}
