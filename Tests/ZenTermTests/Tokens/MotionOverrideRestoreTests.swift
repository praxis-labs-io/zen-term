import AppKit
import XCTest

@testable import ZenTerm

final class MotionOverrideRestoreTests: XCTestCase {
    func test_teardownRestoresTheOverrideTheCaseInherited() throws {
        let original = Motion.isReduceMotionEnabled
        defer { Motion.isReduceMotionEnabled = original }

        var inheritedReads = 0
        Motion.isReduceMotionEnabled = {
            inheritedReads += 1
            return true
        }
        let windowCase = WindowTestCase()
        Motion.isReduceMotionEnabled = { false }

        try windowCase.tearDownWithError()

        let before = inheritedReads
        _ = Motion.isReduceMotionEnabled()
        XCTAssertEqual(
            inheritedReads, before + 1,
            "a window case's pin outlived it, so the next suite reads a closure it never set")
    }
}
