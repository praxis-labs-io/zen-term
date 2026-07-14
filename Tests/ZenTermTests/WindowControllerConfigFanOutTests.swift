import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Integration test for the `.configDidChange` reapply fan-out in `WindowController` (ZEN-102).
///
/// Every persistent component's own `reapplyTheme()` is unit-tested in `ReapplyThemeTests` /
/// `OverlayReapplyThemeTests`, but nothing failed if a line went missing from the observer's
/// hand-maintained list (`WindowController.swift` — `tabBar`, `dock`, `modal?.overlay`,
/// `confirmToast`, …) — the exact stale-chrome bug class ZEN-89 fixed. This mounts the real
/// chrome and drives the actual notification, so dropping `tabBar.reapplyTheme()` from the
/// fan-out fails a test rather than shipping stale chrome after a theme swap.
@MainActor
final class WindowControllerConfigFanOutTests: XCTestCase {
    private var originalTheme: AppTheme!
    private var originalOverride: (() -> TerminalSurface)?
    private var tempRoots: [URL] = []
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        // The real ghostty backend needs a live libghostty app, which a test bundle has no
        // business spinning up — inject a headless stub surface instead.
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDownWithError() throws {
        // The controller's own teardown (kills surfaces, invalidates the title poll, removes the
        // config observer) runs through its NSWindowDelegate entry point.
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    /// A theme whose accent (ANSI slot 5) is a clearly distinct `#00ff00`, built via the same
    /// `ConfigLoader.loadAppTheme` path the other reapply tests use so every derived chrome role
    /// is populated exactly like a real theme swap.
    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-fanout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func test_configDidChange_recolorsPersistentChromeThroughTheFanOut() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        let root = controller.window.contentView!

        guard let tabBar = descendants(of: root).compactMap({ $0 as? TabBarView }).first else {
            return XCTFail("expected the tab bar mounted in the window")
        }
        // The tracer underline is baked to `chrome.accent` at init and reset only by
        // `TabBarView.reapplyTheme()` — a faithful proxy for the fan-out reaching the tab bar.
        let accentBefore = tabBar.tracerColorForTesting
        XCTAssertNotNil(accentBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        NotificationCenter.default.post(name: .configDidChange, object: nil)

        // The observer is registered on `.main`, so its block runs as a queued main-queue op;
        // enqueue a fulfill after it (FIFO on the main run loop) and wait so it has run.
        // The observer is registered on `OperationQueue.main`, so drain on the SAME queue — a
        // `DispatchQueue.main` hop isn't guaranteed to sequence after an OperationQueue.main op.
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        // If the fan-out had dropped `tabBar.reapplyTheme()`, the tracer would still hold the old
        // baked-in accent. Slot 5 provably moved (Rosé Pine Moon → #00ff00), so a working fan-out
        // must change it.
        XCTAssertNotEqual(accentBefore, tabBar.tracerColorForTesting)
    }
}
