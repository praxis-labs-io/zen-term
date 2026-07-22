import AppKit
import XCTest

@testable import ZenTerm

/// The shared `DirectoryPickerField` (workspace folder + tool-float directory both use it): a text
/// field plus a Choose button that opens a native directory panel. A direct button tap isn't
/// mid-gesture, so the sheet attaches reliably here; keyboard reachability of the button in a form
/// is covered by the form suites.
final class DirectoryPickerFieldTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.attachedSheet.map { window?.endSheet($0) }
        window = nil
        super.tearDown()
    }

    func test_chooseButton_isAKeyboardFocusStop() {
        let picker = DirectoryPickerField(placeholder: "Type a path, or Choose")
        XCTAssertTrue(picker.chooseButton.isKeyboardFocusable, "the Choose button must be arrow/Tab reachable")
        XCTAssertEqual(picker.chooseButton.title, "Choose")
    }

    func test_chooseButton_opensTheDirectoryPanel() {
        let picker = DirectoryPickerField(placeholder: "Type a path, or Choose")
        let win = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120))
        win.contentView!.addSubview(picker)
        picker.frame = win.contentView!.bounds
        win.makeKeyAndOrderFront(nil)
        window = win

        picker.chooseButton.onTap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertNotNil(win.attachedSheet, "tapping Choose must attach the directory panel as a sheet")
    }
}
