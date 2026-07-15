import GhosttyKit
import XCTest

@testable import TerminalKit

final class GhosttyMouseShapeTests: XCTestCase {
    // The system cursors (`.iBeam`, `.arrow`, …) are shared singletons, so identity (`===`) is
    // the precise check that the mapping returns exactly that cursor.
    func test_textMapsToIBeam() {
        XCTAssertTrue(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_TEXT) === NSCursor.iBeam)
    }

    func test_pointerMapsToPointingHand() {
        XCTAssertTrue(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_POINTER) === NSCursor.pointingHand)
    }

    func test_notAllowedMapsToOperationNotAllowed() {
        XCTAssertTrue(
            GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED) === NSCursor.operationNotAllowed)
    }

    func test_horizontalResizeMapsToResizeLeftRight() {
        XCTAssertTrue(
            GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_EW_RESIZE) === NSCursor.resizeLeftRight)
    }

    func test_defaultMapsToArrow() {
        XCTAssertTrue(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) === NSCursor.arrow)
    }

    func test_unmappedShapeFallsBackToArrow() {
        // Diagonal resizes have no classic NSCursor, so they take the .arrow fallback.
        XCTAssertTrue(GhosttyHostView.nsCursor(for: GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE) === NSCursor.arrow)
    }
}
