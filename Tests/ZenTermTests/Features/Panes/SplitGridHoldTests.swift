import AppKit
import PaneKit
import XCTest

@testable import ZenTerm

@MainActor
final class SplitGridHoldTests: WindowTestCase {
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

        container.removeFromSuperview()

        XCTAssertEqual(
            holds, [true, false],
            "torn out mid-slide, the container must release its hold — its animation completion "
                + "captures self weakly and will never run once the rebuild drops the last reference")
        withExtendedLifetime(window) {}
    }

    func test_settledSlide_doesNotReleaseAgainOnTeardown() {
        let (window, container) = makeSplit()
        var holds: [Bool] = []
        container.animateSplitIn(
            duration: 0.28, timing: CAMediaTimingFunction(name: .easeOut),
            suspendGrids: { holds.append($0) })

        container.setRatio(0.5)
        XCTAssertEqual(holds, [true, false])

        container.removeFromSuperview()

        XCTAssertEqual(holds, [true, false], "an already-settled slide has no hold left to release")
        withExtendedLifetime(window) {}
    }
}
