import AppKit
import XCTest

@testable import ZenTerm

/// The nav row's keyboard focus reads as the palette/repo-picker accent background fill
/// (`PaletteOverlay.selectionBackground`), not a border. These drive a real window-mounted row
/// through first-responder changes — per "GUI controls need interaction tests", state-only
/// assertions wouldn't prove the fill actually appears and that focus wins over the selection fill.
final class SettingsNavRowTests: WindowTestCase {
    func test_focus_showsPaletteFillNotBorder() {
        let (row, window) = mountedRow()

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, PaletteOverlay.selectionBackground.cgColor)
        XCTAssertEqual(row.layer?.borderWidth, 0)  // focus is a fill, never a ring

        window.makeFirstResponder(nil)
        // Fill clears on blur (unselected row → clear).
        XCTAssertNotEqual(row.layer?.backgroundColor, PaletteOverlay.selectionBackground.cgColor)
    }

    func test_focusFillWinsOverSelectionFill() {
        let (row, window) = mountedRow()

        row.setSelected(true)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(alpha: 0.06).cgColor)

        window.makeFirstResponder(row)
        // A focused row shows the palette focus fill even when it's the selected section.
        XCTAssertEqual(row.layer?.backgroundColor, PaletteOverlay.selectionBackground.cgColor)
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
