import GhosttyKit
import XCTest

@testable import TerminalKit

final class GhosttyMouseShapeTests: XCTestCase {
    func test_textMapsToIBeam() {
        XCTAssertEqual(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_TEXT), .iBeam)
    }

    func test_pointerMapsToPointingHand() {
        XCTAssertEqual(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_POINTER), .pointingHand)
    }

    func test_notAllowedMapsToOperationNotAllowed() {
        XCTAssertEqual(
            GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED), .operationNotAllowed)
    }

    func test_horizontalResizeMapsToResizeLeftRight() {
        XCTAssertEqual(
            GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_EW_RESIZE), .resizeLeftRight)
    }

    func test_defaultMapsToArrow() {
        XCTAssertEqual(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT), .arrow)
    }

    func test_unmappedShapeFallsBackToArrow() {
        // Diagonal resizes have no classic NSCursor, so they take the .arrow fallback.
        XCTAssertEqual(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE), .arrow)
    }
}
