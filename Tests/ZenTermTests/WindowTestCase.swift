import AppKit
import XCTest

@testable import ZenTerm

class WindowTestCase: XCTestCase {
    /// Captured at init, before any setup hook can pin it.
    private let originalReduceMotion = Motion.isReduceMotionEnabled

    /// Not `tearDown`, which runs first and would close windows before a subclass's own teardown.
    override func tearDownWithError() throws {
        try super.tearDownWithError()
        Self.closeAllWindows()
        Motion.isReduceMotionEnabled = originalReduceMotion
    }

    /// Clears `isReleasedWhenClosed`, or `close()` over-releases a window `WindowController` still owns.
    static func closeAllWindows() {
        for window in NSApplication.shared.windows {
            window.isReleasedWhenClosed = false
            window.close()
        }
    }
}
