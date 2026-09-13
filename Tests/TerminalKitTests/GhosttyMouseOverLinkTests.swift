import GhosttyKit
import XCTest

@testable import TerminalKit

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

    func test_emptyMeansThePointerLeft() {
        XCTAssertNil(hoveredLink(""))
    }

    func test_nilPointerMeansThePointerLeft() {
        XCTAssertNil(
            GhosttySurface.hoveredLink(ghostty_action_mouse_over_link_s(url: nil, len: 0)))
    }

    func test_decodeIsLengthDelimitedNotNulTerminated() {
        let bytes: [CChar] = [0x61, 0x00, 0x62]
        let decoded = bytes.withUnsafeBufferPointer { buffer in
            GhosttySurface.hoveredLink(
                ghostty_action_mouse_over_link_s(url: buffer.baseAddress, len: 3))
        }
        XCTAssertEqual(decoded, "a\u{0}b")
    }
}
