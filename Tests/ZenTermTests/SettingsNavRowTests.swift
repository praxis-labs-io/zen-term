import AppKit
import XCTest

@testable import ZenTerm

/// The nav row's focus indicator changed from an accent fill to an accent ring (ZEN-85), so it
/// matches `AppButton` / `Dropdown` / the segments. These drive a real window-mounted row through
/// first-responder changes — per "GUI controls need interaction tests", state-only assertions
/// wouldn't prove the ring actually appears and composes with the selection fill.
final class SettingsNavRowTests: XCTestCase {
    func test_focus_showsAccentRingNotFill() {
        let (row, window) = mountedRow()

        XCTAssertEqual(row.layer?.borderWidth, 0)  // unfocused: no ring

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.borderWidth, 1.5)
        XCTAssertEqual(row.layer?.borderColor, Theme.current.chrome.accent.nsColor.cgColor)
        // Focus is a ring, not a background fill: an unselected focused row shows no selection fill.
        XCTAssertNotEqual(row.layer?.backgroundColor, Theme.current.chrome.ink(alpha: 0.06).cgColor)

        window.makeFirstResponder(nil)
        XCTAssertEqual(row.layer?.borderWidth, 0)  // ring cleared on blur
        XCTAssertNil(row.layer?.borderColor)
    }

    func test_selectionFillComposesWithFocusRing() {
        let (row, window) = mountedRow()

        row.setSelected(true)
        let fill = Theme.current.chrome.ink(alpha: 0.06).cgColor
        XCTAssertEqual(row.layer?.backgroundColor, fill)
        XCTAssertEqual(row.layer?.borderWidth, 0)  // selected but not focused → fill only, no ring

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, fill)  // fill persists under focus
        XCTAssertEqual(row.layer?.borderWidth, 1.5)  // ring layers on top
    }

    /// Returns the window alongside the row so the caller holds a strong reference for the test's
    /// duration — `NSView.window` doesn't retain it — and drives first responder through `window`
    /// directly.
    private func mountedRow() -> (SettingsNavRow, NSWindow) {
        let row = SettingsNavRow(title: "Terminal") {}
        row.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        return (row, window)
    }
}
