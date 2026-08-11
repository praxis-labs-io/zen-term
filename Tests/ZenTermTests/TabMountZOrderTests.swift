import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A canvas transition mounts two canvases at once and brings the incoming one in over the
/// outgoing one. Which of the pair is on top decides whether any of it is visible, and nothing
/// on screen says it went wrong: the transition still runs, the drawer slides of a ⏎ workspace
/// open still run, and all of it plays behind an opaque canvas until the outgoing view is
/// detached — a hard cut that reads as "the animation was removed". Every canvas mounts
/// at the very back of the container so a canvas can't cover a float card dismissing above it,
/// which put the incoming canvas under the outgoing one too.
@MainActor
final class TabMountZOrderTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }  // no libghostty in a unit test
        // Two mounted canvases is what a transition in flight looks like, and Reduce Motion has
        // none in flight: it collapses the slide and detaches the outgoing canvas before this
        // returns. Pin it off so the developer's own accessibility setting can't decide whether
        // the test has anything to look at.
        Motion.isReduceMotionEnabled = { false }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// The container every tab canvas and the tab bar are pinned into.
    private func container(of controller: WindowController) -> NSView? {
        guard let root = controller.window.contentView,
            let bar = descendants(of: root).first(where: { $0 is TabBarView })
        else { return nil }
        return bar.superview
    }

    /// A tab canvas is the container subview hosting the tab's panes.
    private func canvases(in container: NSView) -> [NSView] {
        container.subviews.filter { view in
            descendants(of: view).contains { $0 is PanelHostView }
        }
    }

    func test_incomingCanvasMountsAboveTheOutgoingOne() {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()

        guard let container = container(of: controller) else {
            return XCTFail("the window must hold a tab bar and a canvas container")
        }
        guard let outgoing = canvases(in: container).first else {
            return XCTFail("the first tab's canvas must be mounted after mountAndStart()")
        }

        controller.newTabForTesting()  // ⌘t: the new tab slides in, both canvases up for its length

        let mounted = canvases(in: container)
        XCTAssertEqual(
            mounted.count, 2, "the outgoing canvas stays mounted for the length of the transition")
        guard let incoming = mounted.first(where: { $0 !== outgoing }),
            let incomingIndex = container.subviews.firstIndex(of: incoming),
            let outgoingIndex = container.subviews.firstIndex(of: outgoing)
        else {
            return XCTFail("both canvases must be in the container during the transition")
        }
        XCTAssertGreaterThan(
            incomingIndex, outgoingIndex,
            "the arriving canvas sits above the outgoing one — under it, the transition and "
                + "anything animating on the new tab play invisibly and the swap reads as a cut")
        XCTAssertEqual(
            outgoingIndex, 0,
            "both canvases stay at the back of the container, below a float card dismissing above them")
    }
}
