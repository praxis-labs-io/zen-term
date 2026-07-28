import AppKit
import XCTest

@testable import ZenTerm

/// ZEN-54: every shadowed chrome card derives an explicit `layer.shadowPath` from its rounded
/// bounds (no offscreen shadow pass) and keeps it current as the card resizes.
final class ShadowCardViewTests: WindowTestCase {
    /// Retained so the card stays window-mounted for the duration of each test.
    private var window: NSWindow!

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func mount(_ card: ShadowCardView, size: NSSize) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        window.contentView?.addSubview(card)
        card.frame = NSRect(origin: .zero, size: size)
        card.layoutSubtreeIfNeeded()
    }

    func test_layout_setsShadowPathMatchingBounds() {
        let card = ShadowCardView()
        mount(card, size: NSSize(width: 300, height: 200))
        guard let path = card.layer?.shadowPath else {
            return XCTFail("layout must install a shadowPath")
        }
        XCTAssertEqual(path.boundingBox, card.bounds, "the path covers exactly the card bounds")
    }

    func test_resize_retracksShadowPath() {
        let card = ShadowCardView()
        mount(card, size: NSSize(width: 300, height: 200))
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            card.layer?.shadowPath?.boundingBox, card.bounds,
            "a frame-driven resize must refresh the path")
    }

    func test_degenerateFrame_clampsRadiusWithoutTrapping() {
        let card = ShadowCardView()
        mount(card, size: NSSize(width: 8, height: 8))  // radius 12 > 8/2 would trap CGPath
        XCTAssertNotNil(card.layer?.shadowPath)
    }

    func test_collapseToZeroSize_clearsShadowPath() {
        let card = ShadowCardView()
        mount(card, size: NSSize(width: 300, height: 200))
        XCTAssertNotNil(card.layer?.shadowPath)

        card.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        card.layoutSubtreeIfNeeded()

        XCTAssertNil(
            card.layer?.shadowPath,
            "a collapsed card must not keep casting its previous full-size shadow")
    }
}
