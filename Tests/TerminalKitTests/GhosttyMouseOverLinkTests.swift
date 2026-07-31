import GhosttyKit
import XCTest

@testable import TerminalKit

/// `GHOSTTY_ACTION_MOUSE_OVER_LINK` → the seam's hovered-link value (ZEN-24). libghostty sends
/// the URL while the pointer is over a live link and an empty string when it leaves; the seam
/// carries "left" as nil so consumers get one optional instead of a sentinel string.
final class GhosttyMouseOverLinkTests: XCTestCase {
    private func hoveredLink(_ url: String) -> String? {
        url.withCString { ptr in
            GhosttySurface.hoveredLink(
                ghostty_action_mouse_over_link_s(url: ptr, len: numericCast(url.utf8.count)))
        }
    }

    func test_urlIsCarriedThrough() {
        XCTAssertEqual(
            hoveredLink("https://example.com/a/long/path?q=1"),
            "https://example.com/a/long/path?q=1")
    }

    /// Leaving a link arrives as an empty payload, and the seam's word for that is nil.
    func test_emptyMeansThePointerLeft() {
        XCTAssertNil(hoveredLink(""))
    }

    func test_nilPointerMeansThePointerLeft() {
        XCTAssertNil(
            GhosttySurface.hoveredLink(ghostty_action_mouse_over_link_s(url: nil, len: 0)))
    }

    /// The payload is length-delimited, not NUL-terminated: an OSC 8 URI is program-chosen bytes,
    /// so a `String(cString:)` decode would silently truncate at an interior NUL.
    func test_decodeIsLengthDelimitedNotNulTerminated() {
        let bytes: [CChar] = [0x61, 0x00, 0x62]  // "a", NUL, "b"
        let decoded = bytes.withUnsafeBufferPointer { buffer in
            GhosttySurface.hoveredLink(
                ghostty_action_mouse_over_link_s(url: buffer.baseAddress, len: 3))
        }
        XCTAssertEqual(decoded, "a\u{0}b")
    }
}
