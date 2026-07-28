import AppKit
import XCTest

@testable import ZenTerm

final class IconPickerFieldTests: WindowTestCase {
    /// ZEN-268 (same class as `Dropdown`): the open grid card lives on `window.contentView`, not
    /// inside the field's own subtree, so tearing the field's host out of the window — what a
    /// tab-switch `closeModal()` does to the workspace / tool-float form hosting this field — must
    /// still take the card with it. Without a leave-the-window hook the grid orphans on the content
    /// view, stuck over every tab with no way to clear but restart.
    func test_removingHostFromWindow_closesOpenGrid() {
        let field = IconPickerField(selected: "hammer")
        field.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Host the field inside a container standing in for the form overlay, so the teardown
        // removes an ANCESTOR of the field (not the field directly) — the `closeModal()` path.
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(host)
        host.addSubview(field)
        field.frame = NSRect(x: 20, y: 300, width: 220, height: 30)
        window.makeFirstResponder(field)
        field.openForTesting()
        XCTAssertTrue(field.isPopoverOpen)
        XCTAssertTrue(window.contentView!.subviews.contains { $0 is ShadowCardView })

        host.removeFromSuperview()  // the form being torn down out from under the field

        XCTAssertFalse(field.isPopoverOpen, "grid closes when the field leaves the window")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no orphaned grid card left drawn on the content view")
    }
}
