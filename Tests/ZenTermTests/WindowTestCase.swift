import AppKit
import XCTest

@testable import ZenTerm

/// Base class for suites that mount a view in a real window.
///
/// XCTest tears down no AppKit state between cases, so every window a test opened stayed on screen
/// for the rest of the run. A full suite climbed monotonically to 69 live window-server surfaces,
/// several Metal-backed: each test ran under more load than the one before it, and the run took
/// twice as long as it needed to. Inheriting this instead of `XCTestCase` sweeps them.
///
/// `close()` rather than `orderOut(_:)` on purpose. A `WindowController` drives its teardown from
/// `windowWillClose`, so closing also invalidates the title poll and shuts down every tab's shells.
/// Ordering out leaves both running, and the shells then outlive the process as orphans.
class WindowTestCase: XCTestCase {
    /// Whatever `Motion.isReduceMotionEnabled` was before this case pinned it.
    ///
    /// Captured in the property initializer rather than a setup hook, because XCTest builds the
    /// case instance before any hook runs: this sees the pristine closure without depending on
    /// which setup hook a subclass pins from, or on the order XCTest runs them in.
    ///
    /// Suites pin the override so animations resolve instantly and a card is mounted by the time
    /// an assertion reads the tree. Restoring here is what keeps that from deciding another
    /// suite's result: a case that pins Reduce Motion *off* to watch an animation run reads
    /// whatever the last file left behind otherwise, and passes or fails on file order.
    private let originalReduceMotion = Motion.isReduceMotionEnabled

    /// `tearDownWithError`, not `tearDown`: XCTest runs `tearDown` first, and most suites here do
    /// their cleanup in `tearDownWithError`. Sweeping from `tearDown` closed their windows before
    /// their own teardown body ran, which turned an explicit `controller?.windowWillClose(...)`
    /// into a no-op absorbed by `WindowController`'s `didTearDown` guard and quietly retired the
    /// coverage those lines exist for. Every subclass calls `super.tearDownWithError()` last, so
    /// sweeping after it puts the sweep last.
    override func tearDownWithError() throws {
        try super.tearDownWithError()
        Self.closeAllWindows()
        // After the sweep: closing a window drives `WindowController`'s teardown, and that should
        // still run under the Reduce Motion setting the test chose, not the machine's.
        Motion.isReduceMotionEnabled = originalReduceMotion
    }

    /// Static so `WindowSweepTests` can drive it directly. A teardown hook that stops running
    /// fails nothing and the suite silently goes back to leaking, which is the shape of the leak
    /// itself, so the sweep needs a test that does not depend on the hook firing.
    ///
    /// Every window, not just the visible ones: one never ordered in costs no window-server
    /// surface, but closing is what fires `windowWillClose`, and filtering on `isVisible` skipped
    /// 35 of 43 teardowns in the suites measured.
    static func closeAllWindows() {
        // `windows` is an Array, a value type, so iterating it is safe even though each `close()`
        // removes its own entry.
        for window in NSApplication.shared.windows {
            // Not optional, and not a precaution. `isReleasedWhenClosed` defaults to true for a
            // window built in code, so `close()` releases it while ARC still counts the owner's
            // reference: `WindowController` holds `let window: HostWindow`, and leaving the flag
            // alone segfaults the suite (signal 11, in ConfigFanOutDifferentialTests). The cost is
            // that a closed window stays in `NSApp.windows` for the run, so the sweep re-walks
            // them. That is bounded by the number of windows the suite builds, roughly 70, and
            // re-closing a closed window neither re-posts `willClose` nor costs anything
            // measurable. The window-server surfaces, the thing actually leaking, are still
            // reclaimed.
            window.isReleasedWhenClosed = false
            window.close()
        }
    }
}
