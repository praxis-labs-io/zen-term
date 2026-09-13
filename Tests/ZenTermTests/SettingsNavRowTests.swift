import AppKit
import XCTest

@testable import ZenTerm

final class SettingsNavRowTests: WindowTestCase {
    func test_focus_showsPaletteFillNotBorder() {
        let (row, window) = mountedRow()

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)
        XCTAssertEqual(row.layer?.borderWidth, 0)

        window.makeFirstResponder(nil)
        XCTAssertNotEqual(row.layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)
    }

    func test_focusFillWinsOverSelectionFill() {
        let (row, window) = mountedRow()

        row.setSelected(true)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.fill(.rest).cgColor)

        window.makeFirstResponder(row)
        XCTAssertEqual(row.layer?.backgroundColor, Theme.current.chrome.selectionFill.cgColor)
    }

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
