import AppKit
import XCTest

@testable import ZenTerm

final class KeybindHintBubbleTests: WindowTestCase {
    private final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
    }

    private func placedFrame(in host: NSView, at origin: NSPoint) -> (frame: NSRect, fitted: NSSize) {
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let bubble = KeybindHintBubble()
        host.addSubview(bubble)
        var fitted = NSSize.zero
        bubble.place { size in
            fitted = size
            return origin
        }
        return (bubble.frame, fitted)
    }

    func test_place_putsTheBubbleAtTheOrigin_inAnUnflippedHost() {
        let placed = placedFrame(in: NSView(), at: NSPoint(x: 30, y: 40))

        XCTAssertEqual(placed.frame, NSRect(origin: NSPoint(x: 30, y: 40), size: placed.fitted))
    }

    func test_place_putsTheBubbleAtTheOrigin_inAFlippedHost() {
        let placed = placedFrame(in: FlippedHost(), at: NSPoint(x: 30, y: 40))

        XCTAssertEqual(placed.frame, NSRect(origin: NSPoint(x: 30, y: 40), size: placed.fitted))
    }

    func test_place_movesTheBubbleWhenAskedAgain() {
        let host = NSView()
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let bubble = KeybindHintBubble()
        host.addSubview(bubble)
        bubble.place { _ in NSPoint(x: 30, y: 40) }

        bubble.place { _ in NSPoint(x: 50, y: 60) }

        XCTAssertEqual(bubble.frame.origin, NSPoint(x: 50, y: 60))
    }
}
