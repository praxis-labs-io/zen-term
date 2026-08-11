import AppKit
import XCTest

@testable import ZenTerm

/// `WindowTestCase` puts `Motion.isReduceMotionEnabled` back from a teardown hook, and a teardown
/// hook that stops firing fails nothing: every window suite keeps passing while its pin leaks into
/// whatever runs next, which is the leak itself. So the restore gets a test that drives it rather
/// than one that relies on it, the same reason `WindowSweepTests` exists.
final class MotionOverrideRestoreTests: XCTestCase {
    func test_teardownRestoresTheOverrideTheCaseInherited() throws {
        let original = Motion.isReduceMotionEnabled
        defer { Motion.isReduceMotionEnabled = original }

        // Pinned before the case is built, because building it is when the capture happens.
        Motion.isReduceMotionEnabled = { true }
        let windowCase = WindowTestCase()
        Motion.isReduceMotionEnabled = { false }  // stands in for a suite pinning in its setup

        try windowCase.tearDownWithError()

        XCTAssertTrue(
            Motion.isReduceMotionEnabled(),
            "a window case's pin outlived it, so the next suite reads Reduce Motion off")
    }
}
