import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class EdgeFadeTests: XCTestCase {
    func test_fadesDeeperThanTheirView_keepTheStopsInOrder() throws {
        let fade = EdgeFade(axis: .vertical)

        fade.update(frame: NSRect(x: 0, y: 0, width: 240, height: 20), start: 16, end: 16)

        let stops = try XCTUnwrap(fade.layer.locations).map(\.doubleValue)
        XCTAssertEqual(stops, stops.sorted(), "a descending stop renders as a torn mask")
        XCTAssertEqual(stops.first, 0)
        XCTAssertEqual(stops.last, 1)
    }

    func test_fadesThatFit_keepTheirDepth() throws {
        let fade = EdgeFade(axis: .vertical)

        fade.update(frame: NSRect(x: 0, y: 0, width: 240, height: 200), start: 16, end: 0)

        let stops = try XCTUnwrap(fade.layer.locations).map(\.doubleValue)
        XCTAssertEqual(stops[1], 0.08, accuracy: 0.001, "16 of 200")
        XCTAssertEqual(stops[2], 1)
    }
}
