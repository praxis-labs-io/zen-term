import AppKit
import XCTest

@testable import ZenTerm

final class KeybindChipTests: WindowTestCase {
    private func mount() -> (KeybindChip, NSWindow) {
        let chip = KeybindChip()
        chip.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(chip)
        chip.frame = NSRect(x: 0, y: 0, width: 120, height: ChromeMetrics.Height.control)
        chip.render(shortcut: "⌘T")
        return (chip, window)
    }

    func test_focus_ringsTheChipInTheFocusRing() {
        let (chip, window) = mount()
        XCTAssertEqual(chip.layer?.borderColor?.alpha, 0)

        XCTAssertTrue(window.makeFirstResponder(chip))

        XCTAssertEqual(chip.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
    }

    func test_capturing_ringsTheChipInAccent() {
        let (chip, window) = mount()
        XCTAssertTrue(window.makeFirstResponder(chip))

        chip.setCapturing(true)

        XCTAssertEqual(chip.layer?.borderColor, Theme.current.chrome.accent.nsColor.cgColor)
    }
}
