import AppKit
import XCTest

@testable import ZenTerm

final class KeybindHintBubbleTests: WindowTestCase {
    private final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
    }

    private let gap = ChromeMetrics.Spacing.s6

    private func hosted(in host: NSView, anchorAt anchorFrame: NSRect) -> (bubble: KeybindHintBubble, anchor: NSView) {
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let anchor = NSView(frame: anchorFrame)
        host.addSubview(anchor)
        let bubble = KeybindHintBubble()
        host.addSubview(bubble)
        return (bubble, anchor)
    }

    func test_place_centersTheBubbleAboveTheAnchor_inAnUnflippedHost() {
        let (bubble, anchor) = hosted(in: NSView(), anchorAt: NSRect(x: 280, y: 400, width: 40, height: 20))

        bubble.place(near: anchor)

        XCTAssertEqual(bubble.frame.midX, anchor.frame.midX, accuracy: 0.5)
        XCTAssertEqual(bubble.frame.minY, anchor.frame.maxY + gap)
    }

    func test_place_centersTheBubbleAboveTheAnchor_inAFlippedHost() {
        let (bubble, anchor) = hosted(in: FlippedHost(), anchorAt: NSRect(x: 280, y: 400, width: 40, height: 20))

        bubble.place(near: anchor)

        XCTAssertEqual(bubble.frame.midX, anchor.frame.midX, accuracy: 0.5)
        XCTAssertEqual(bubble.frame.maxY, anchor.frame.minY - gap)
    }

    func test_place_putsTheBubbleBelowTheAnchor_whenThereIsNoRoomAbove() {
        let (bubble, anchor) = hosted(in: FlippedHost(), anchorAt: NSRect(x: 280, y: 10, width: 40, height: 20))

        bubble.place(near: anchor)

        XCTAssertEqual(bubble.frame.minY, anchor.frame.maxY + gap)
    }

    func test_place_keepsTheBubbleInsideTheHost_nearAnEdge() {
        let (bubble, anchor) = hosted(in: FlippedHost(), anchorAt: NSRect(x: 570, y: 400, width: 20, height: 20))

        bubble.place(near: anchor)

        XCTAssertEqual(bubble.frame.maxX, 600 - ChromeMetrics.Spacing.s8)
    }

    func test_place_movesTheBubbleWhenAskedAgain() {
        let host = FlippedHost()
        let (bubble, first) = hosted(in: host, anchorAt: NSRect(x: 280, y: 400, width: 40, height: 20))
        let second = NSView(frame: NSRect(x: 180, y: 450, width: 40, height: 20))
        host.addSubview(second)
        bubble.place(near: first)

        bubble.place(near: second)

        XCTAssertEqual(bubble.frame.midX, second.frame.midX, accuracy: 0.5)
        XCTAssertEqual(bubble.frame.maxY, second.frame.minY - gap)
    }

    func test_place_putsTheBubbleNearTheAnchor_afterItMovesToAnotherHost() {
        let (bubble, first) = hosted(in: FlippedHost(), anchorAt: NSRect(x: 280, y: 400, width: 40, height: 20))
        bubble.place(near: first)
        let second = FlippedHost(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let anchor = NSView(frame: NSRect(x: 180, y: 450, width: 40, height: 20))
        second.addSubview(anchor)

        bubble.removeFromSuperview()
        second.addSubview(bubble)
        bubble.place(near: anchor)

        XCTAssertEqual(bubble.frame.midX, anchor.frame.midX, accuracy: 0.5)
        XCTAssertEqual(bubble.frame.maxY, anchor.frame.minY - gap)
    }
}
