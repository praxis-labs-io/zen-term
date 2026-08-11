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
        // Final model state matches the animated path: scaled (hidden), not identity.
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

    // MARK: - Config override

    func test_motionConfig_forcesOnAndOff() {
        MotionConfig.apply(.on)
        XCTAssertTrue(Motion.isReduceMotionEnabled())
        MotionConfig.apply(.off)
        XCTAssertFalse(Motion.isReduceMotionEnabled())
    }

    func test_motionConfig_systemRestoresTheSystemReader() {
        // `.system` runs on every config change now, so it must UNDO a prior on/off override and
        // fall back to reading the OS setting — not leave the forced closure in place.
        let systemValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        MotionConfig.apply(.on)
        XCTAssertTrue(Motion.isReduceMotionEnabled())
        MotionConfig.apply(.system)
        XCTAssertEqual(Motion.isReduceMotionEnabled(), systemValue, "`.system` must restore the OS reader")
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
