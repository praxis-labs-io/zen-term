import AppKit
import XCTest

@testable import ZenTerm

final class FieldChromeTests: WindowTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func mount(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 20, y: 20, width: 220, height: ChromeMetrics.Height.control)
    }

    private func assertChrome(
        _ view: NSView, focused: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let chrome = Theme.current.chrome
        let border = focused ? chrome.focusRing : chrome.fill(alpha: ChromeTheme.border)
        XCTAssertEqual(view.layer?.borderColor, border.cgColor, message, file: file, line: line)
        XCTAssertEqual(view.layer?.borderWidth, ChromeMetrics.Border.width, message, file: file, line: line)
        XCTAssertEqual(view.layer?.backgroundColor, chrome.fill(.rest).cgColor, message, file: file, line: line)
    }

    func test_eachBoxedInput_ringsOnFocus_andRestsAfter() {
        let fieldBox = FieldBox(placeholder: "Name")
        let textArea = TextAreaBox(placeholder: "Notes")
        let iconPicker = IconPickerField(selected: "hammer")
        let regionField = RegionCommandField(region: .main)
        let inputs: [(String, NSView, NSResponder)] = [
            ("FieldBox", fieldBox, fieldBox.field),
            ("TextAreaBox", textArea, textArea.textView),
            ("IconPickerField", iconPicker, iconPicker),
            ("RegionCommandField", regionField, regionField.field),
        ]
        for (name, view, responder) in inputs {
            mount(view)
            assertChrome(view, focused: false, "\(name) at rest")

            XCTAssertTrue(window.makeFirstResponder(responder), "\(name) takes focus")
            assertChrome(view, focused: true, "\(name) focused")

            window.makeFirstResponder(nil)
            assertChrome(view, focused: false, "\(name) after focus leaves")
        }
    }
}
