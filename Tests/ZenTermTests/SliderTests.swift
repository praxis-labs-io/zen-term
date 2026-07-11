import XCTest

@testable import ZenTerm

final class SliderTests: XCTestCase {
    func test_snap_clampsToRange() {
        XCTAssertEqual(Slider.snap(1.5, range: 0...1, step: 0.02), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Slider.snap(-0.3, range: 0...1, step: 0.02), 0.0, accuracy: 0.0001)
    }

    func test_snap_quantizesToStepGrid() {
        XCTAssertEqual(Slider.snap(0.837, range: 0...1, step: 0.02), 0.84, accuracy: 0.0001)
        XCTAssertEqual(Slider.snap(0.28, range: 0.1...0.9, step: 0.01), 0.28, accuracy: 0.0001)
    }

    func test_nudged_movesByStepAndClamps() {
        XCTAssertEqual(Slider.nudged(0.82, steps: 1, range: 0...1, step: 0.02), 0.84, accuracy: 0.0001)
        XCTAssertEqual(Slider.nudged(0.82, steps: -1, range: 0...1, step: 0.02), 0.80, accuracy: 0.0001)
        XCTAssertEqual(Slider.nudged(1.0, steps: 1, range: 0...1, step: 0.02), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Slider.nudged(0.0, steps: -1, range: 0...1, step: 0.02), 0.0, accuracy: 0.0001)
    }
}
