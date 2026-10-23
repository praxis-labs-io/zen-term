import XCTest

@testable import ZenTerm

final class ToastThrottleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func test_aRepeatInsideTheInterval_isHeld() {
        var throttle = ToastThrottle<String>()
        XCTAssertTrue(throttle.allows("split", at: start))
        XCTAssertFalse(throttle.allows("split", at: start.addingTimeInterval(2.9)))
    }

    func test_aRepeatAfterTheInterval_isShown() {
        var throttle = ToastThrottle<String>()
        XCTAssertTrue(throttle.allows("split", at: start))
        XCTAssertTrue(throttle.allows("split", at: start.addingTimeInterval(3)))
    }

    func test_aDifferentKey_isShownInsideTheInterval() {
        var throttle = ToastThrottle<String>()
        XCTAssertTrue(throttle.allows("split", at: start))
        XCTAssertTrue(throttle.allows("close", at: start.addingTimeInterval(1)))
        XCTAssertFalse(throttle.allows("close", at: start.addingTimeInterval(2)))
    }

    func test_anUnkeyedThrottle_holdsEveryRepeat() {
        var throttle = ToastThrottle<Bool>()
        XCTAssertTrue(throttle.allows(at: start))
        XCTAssertFalse(throttle.allows(at: start.addingTimeInterval(1)))
    }
}
