import AppKit
import XCTest

/// Base class for suites that mount a view in a real window.
///
/// XCTest tears down no AppKit state between cases, so every window a test orders in stays on
/// screen for the rest of the run. A full suite peaked at 69 live window-server surfaces, several
/// Metal-backed, and the count only ever climbed (ZEN-312): each test ran under more load than the
/// one before it. Inheriting this instead of `XCTestCase` sweeps them.
///
/// `close()` rather than `orderOut(_:)` on purpose. A `WindowController` drives its teardown from
/// `windowWillClose`, so closing also invalidates the title poll and shuts down every tab's shells.
/// Ordering out leaves both running, and the shells then outlive the process as orphans.
class WindowTestCase: XCTestCase {
    override func tearDown() {
        // Every window, not just the visible ones. A window that was never ordered in costs no
        // window-server surface, but it still owns its view tree, and closing is what fires
        // `windowWillClose`: filtering on `isVisible` skipped 35 of 43 teardowns in the suites
        // measured, including every one that mounts its host in a window it never orders front.
        //
        // `windows` is live: closing mutates it, and a `WindowController` close removes its own
        // entry through `onClosed`. Snapshot before iterating.
        for window in Array(NSApplication.shared.windows) {
            // `isReleasedWhenClosed` defaults to true for a window built in code, so `close()`
            // would free one the suite still holds in a stored property, and the next access is a
            // use-after-free. Clear it first.
            window.isReleasedWhenClosed = false
            window.close()
        }
        super.tearDown()
    }
}
