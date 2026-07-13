import AppKit
import XCTest

@testable import ZenTerm

/// ZEN-54: every shadowed chrome card derives an explicit `layer.shadowPath` from its rounded
/// bounds (no offscreen shadow pass) and keeps it current as the card resizes.
final class ShadowCardViewTests: XCTestCase {
    private func mount(_ card: ShadowCardView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        window.contentView?.addSubview(card)
        card.frame = NSRect(origin: .zero, size: size)
        card.layoutSubtreeIfNeeded()
        return window
    }

    func test_layout_setsShadowPathMatchingBounds() {
        let card = ShadowCardView()
        _ = mount(card, size: NSSize(width: 300, height: 200))
        guard let path = card.layer?.shadowPath else {
            return XCTFail("layout must install a shadowPath")
        }
        XCTAssertEqual(path.boundingBox, card.bounds, "the path covers exactly the card bounds")
    }

    func test_resize_retracksShadowPath() {
        let card = ShadowCardView()
        _ = mount(card, size: NSSize(width: 300, height: 200))
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            card.layer?.shadowPath?.boundingBox, card.bounds,
            "a frame-driven resize must refresh the path")
    }

    func test_degenerateFrame_clampsRadiusWithoutTrapping() {
        let card = ShadowCardView()
        _ = mount(card, size: NSSize(width: 8, height: 8))  // radius 12 > 8/2 would trap CGPath
        XCTAssertNotNil(card.layer?.shadowPath)
    }
}
