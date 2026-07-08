import AppKit
import XCTest

@testable import ZenTerm

final class MotionTests: XCTestCase {
    override func tearDown() {
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        super.tearDown()
    }

    // MARK: - Reduce Motion collapses to an instant, synchronous apply

    func test_reduceMotion_springScaleFadeAppearing_appliesFinalStateSynchronously() {
        Motion.isReduceMotionEnabled = { true }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        var ran = false
        Motion.springScaleFade(view, appearing: true) { ran = true }

        XCTAssertTrue(ran, "completion must run synchronously under Reduce Motion")
        XCTAssertEqual(view.layer?.opacity, 1)
        XCTAssertTrue(CATransform3DIsIdentity(view.layer!.transform))
    }

    func test_reduceMotion_springScaleFadeDisappearing_endsHidden() {
        Motion.isReduceMotionEnabled = { true }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        var ran = false
        Motion.springScaleFade(view, appearing: false) { ran = true }

        XCTAssertTrue(ran)
        XCTAssertEqual(view.layer?.opacity, 0)
    }

    func test_reduceMotion_slide_settlesInPlaceSynchronously() {
        Motion.isReduceMotionEnabled = { true }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        var ran = false
        Motion.slide(view, offset: CGSize(width: 0, height: -200), appearing: true) { ran = true }

        XCTAssertTrue(ran, "completion must run synchronously under Reduce Motion")
        XCTAssertTrue(CATransform3DIsIdentity(view.layer!.transform), "settles at rest")
    }

    func test_reduceMotion_fade_appliesTargetSynchronously() {
        Motion.isReduceMotionEnabled = { true }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))

        var ran = false
        Motion.fade(view, to: 0) { ran = true }

        XCTAssertTrue(ran)
        XCTAssertEqual(view.layer?.opacity, 0)
    }

    func test_reduceMotion_ease_setsModelValueAndRunsCompletion() {
        Motion.isReduceMotionEnabled = { true }
        let layer = CALayer()
        layer.opacity = 0

        var ran = false
        Motion.ease(layer, keyPath: "opacity", to: Float(1)) { ran = true }

        XCTAssertTrue(ran)
        XCTAssertEqual(layer.opacity, 1)
    }

    // MARK: - Pure geometry

    func test_centeredScale_holdsTheCenterFixed() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let t = Motion.centeredScale(0.5, in: bounds)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let moved = center.applying(CATransform3DGetAffineTransform(t))

        XCTAssertEqual(moved.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(moved.y, center.y, accuracy: 0.0001)
    }
}
