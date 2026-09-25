import AppKit
import XCTest

@testable import ZenTerm

class WindowTestCase: XCTestCase {
    /// Captured at init, before any setup hook can pin it.
    private let originalReduceMotion = Motion.isReduceMotionEnabled

    // Fixtures open worktrees at folders that were never created, which the removal check would read as deleted.
    override func setUpWithError() throws {
        try super.setUpWithError()
        WorktreeStore.isRemovedOverrideForTesting = { _ in false }
    }

    /// Not `tearDown`, which runs first and would close windows before a subclass's own teardown.
    override func tearDownWithError() throws {
        try super.tearDownWithError()
        Self.closeAllWindows()
        Motion.isReduceMotionEnabled = originalReduceMotion
        WorktreeStore.isRemovedOverrideForTesting = nil
    }

    @MainActor
    func toastTexts(in c: WindowController) -> [String] {
        guard let content = c.window.contentView else { return [] }
        return Self.descendants(of: content).compactMap { $0 as? ToastView }
            .flatMap { Self.descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Clears `isReleasedWhenClosed`, or `close()` over-releases a window `WindowController` still owns.
    static func closeAllWindows() {
        for window in NSApplication.shared.windows {
            window.isReleasedWhenClosed = false
            window.close()
        }
    }
}
