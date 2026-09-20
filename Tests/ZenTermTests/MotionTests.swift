import AppKit
import XCTest

@testable import ZenTerm

final class MotionTests: XCTestCase {
    private let originalReduceMotion = Motion.isReduceMotionEnabled

    override func tearDown() {
        Motion.isReduceMotionEnabled = originalReduceMotion
        super.tearDown()
    }

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
        XCTAssertFalse(CATransform3DIsIdentity(view.layer!.transform))
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

    func test_reduceMotion_slideFade_keepsFadingInsteadOfSnapping() {
        Motion.isReduceMotionEnabled = { true }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        Motion.slideFade(view, appearing: true, from: CGVector(dx: -240, dy: 0))

        XCTAssertNotNil(view.layer?.animation(forKey: "motion.opacity"), "Reduce Motion still fades")
        XCTAssertNil(view.layer?.animation(forKey: "motion.slide"), "Reduce Motion drops the movement")
        XCTAssertEqual(view.layer?.opacity, 1)
    }

    func test_slideFade_appearing_slidesAndFades() {
        Motion.isReduceMotionEnabled = { false }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        Motion.slideFade(view, appearing: true, from: CGVector(dx: -240, dy: 0))

        let slide = view.layer?.animation(forKey: "motion.slide") as? CABasicAnimation
        XCTAssertEqual((slide?.fromValue as? NSValue)?.sizeValue.width, -240)
        XCTAssertEqual((slide?.toValue as? NSValue)?.sizeValue.width, 0)
        XCTAssertNotNil(view.layer?.animation(forKey: "motion.opacity"))
        XCTAssertEqual(view.layer?.opacity, 1)
    }

    func test_slideFade_disappearing_parksAndEndsHidden() {
        Motion.isReduceMotionEnabled = { false }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        Motion.slideFade(view, appearing: false, from: CGVector(dx: -240, dy: 0))

        let slide = view.layer?.animation(forKey: "motion.slide") as? CABasicAnimation
        XCTAssertEqual((slide?.fromValue as? NSValue)?.sizeValue.width, 0)
        XCTAssertEqual((slide?.toValue as? NSValue)?.sizeValue.width, -240)
        XCTAssertEqual(view.layer?.opacity, 0)
    }

    func test_slideFade_reversedMidFlight_neverFlashesToFullyVisible() {
        Motion.isReduceMotionEnabled = { false }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(view)
        view.wantsLayer = true
        window.orderFront(nil)
        CATransaction.flush()

        Motion.slideFade(view, appearing: true, from: CGVector(dx: -240, dy: 0))
        Motion.slideFade(view, appearing: false, from: CGVector(dx: -240, dy: 0))

        let fade = view.layer?.animation(forKey: "motion.opacity") as? CABasicAnimation
        XCTAssertEqual(fade?.toValue as? Float, 0)
        XCTAssertNotNil(view.layer?.presentation(), "premise: the layer is rendered, so it has a presentation")
        XCTAssertNotEqual(
            fade?.fromValue as? Float, 1,
            "reversing inside the duration must pick the card up where it is, not flash it to full")
    }

    func test_motionConfig_forcesOnAndOff() {
        MotionConfig.apply(.on)
        XCTAssertTrue(Motion.isReduceMotionEnabled())
        MotionConfig.apply(.off)
        XCTAssertFalse(Motion.isReduceMotionEnabled())
    }

    func test_motionConfig_systemRestoresTheSystemReader() {
        let systemValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        MotionConfig.apply(.on)
        XCTAssertTrue(Motion.isReduceMotionEnabled())
        MotionConfig.apply(.system)
        XCTAssertEqual(Motion.isReduceMotionEnabled(), systemValue, "`.system` must restore the OS reader")
    }

    func test_centeredScale_holdsTheCenterFixed() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let t = Motion.centeredScale(0.5, in: bounds)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let moved = center.applying(CATransform3DGetAffineTransform(t))

        XCTAssertEqual(moved.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(moved.y, center.y, accuracy: 0.0001)
    }
}
