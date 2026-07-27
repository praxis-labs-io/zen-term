import AppKit
import PaneKit
import XCTest

@testable import ZenTerm

/// `animateSplitIn` freezes every canvas surface's grid for the length of the slide and releases
/// them from `settleSplitIn`, which normally runs from the animation's completion. That completion
/// captures the container weakly, and `PaneCanvasController.rebuildViews` drops every split view
/// from both the canvas and `splitViewByID` in one pass — so a rebuild landing mid-slide
/// deallocates the container and the completion never runs at all.
///
/// The freeze would then never be released and those panes would stop reflowing for the life of
/// the surface: a terminal that silently ignores every future resize, with nothing on screen to
/// say why. Exactly the silently-dead class, and not something a runbook check would catch, since
/// it needs a rebuild to land inside a 0.28s window.
@MainActor
final class SplitGridHoldTests: XCTestCase {
    /// Build a laid-out one-split container in a real window, so `animateSplitIn`'s geometry guards
    /// (non-nil children, extent > 1) are actually satisfied rather than silently skipped.
    private func makeSplit() -> (window: NSWindow, container: SplitContainerView) {
        let node = PaneNode.split(
            id: SplitID(1), axis: .vertical, ratio: 0.5, a: .leaf(PaneID(1)), b: .leaf(PaneID(2)))
        let container = SplitContainerView(node: node) { _ in NSView() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, container)
    }

    func test_containerTornOutMidSlide_releasesTheGridHold() {
        let (window, container) = makeSplit()
        var holds: [Bool] = []
        container.animateSplitIn(
            duration: 0.28, timing: CAMediaTimingFunction(name: .easeOut),
            suspendGrids: { holds.append($0) })
        XCTAssertEqual(holds, [true], "the slide should have taken the hold")

        // What a rebuild does to a container whose slide is still in flight.
        container.removeFromSuperview()

        XCTAssertEqual(
            holds, [true, false],
            "torn out mid-slide, the container must release its hold — its animation completion "
                + "captures self weakly and will never run once the rebuild drops the last reference")
        withExtendedLifetime(window) {}
    }

    /// The teardown release must not double-release when the slide already settled normally: a
    /// second release would pay down a hold another in-flight animation still owns.
    func test_settledSlide_doesNotReleaseAgainOnTeardown() {
        let (window, container) = makeSplit()
        var holds: [Bool] = []
        container.animateSplitIn(
            duration: 0.28, timing: CAMediaTimingFunction(name: .easeOut),
            suspendGrids: { holds.append($0) })

        container.setRatio(0.5)  // settles the in-flight slide, releasing the hold
        XCTAssertEqual(holds, [true, false])

        container.removeFromSuperview()

        XCTAssertEqual(holds, [true, false], "an already-settled slide has no hold left to release")
        withExtendedLifetime(window) {}
    }
}
