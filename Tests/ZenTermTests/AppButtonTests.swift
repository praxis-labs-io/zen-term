import AppKit
import XCTest

@testable import ZenTerm

/// Focus on a pill is an accent ring *and* accent text, so a keyboard user gets the same signal on
/// a quiet button as on a link. `.destructive` is the one opt-out. These drive a real
/// window-mounted button: a state-only check passes while `becomeFirstResponder` never fires.
final class AppButtonTests: WindowTestCase {
    private func mount(_ variant: AppButton.Variant) -> (AppButton, NSWindow) {
        let button = AppButton(title: "Add workspace", variant: variant) {}
        button.isKeyboardFocusable = true
        button.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(button)
        button.frame = NSRect(x: 0, y: 0, width: 120, height: 26)
        return (button, window)
    }

    private func titleColor(_ button: AppButton) -> NSColor? {
        guard button.attributedTitle.length > 0 else { return nil }
        return button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    func test_focus_tintsAQuietPillsTextAccent() {
        for variant in [AppButton.Variant.muted, .secondary] {
            let (button, window) = mount(variant)
            XCTAssertNotEqual(
                titleColor(button), Theme.current.chrome.accent.nsColor, "\(variant) starts accent")

            XCTAssertTrue(window.makeFirstResponder(button), "\(variant) refused focus")

            XCTAssertEqual(
                titleColor(button), Theme.current.chrome.accent.nsColor,
                "\(variant) shows focus with the ring alone")
        }
    }

    func test_focus_leavesADestructivePillsWarningTone() {
        let (button, window) = mount(.destructive)

        XCTAssertTrue(window.makeFirstResponder(button))

        XCTAssertEqual(
            titleColor(button), Theme.current.chrome.destructive.nsColor,
            "the warning tone is the message; focus must not take it")
    }

    /// The ring is the other half and has to survive the text change.
    func test_focus_stillDrawsTheAccentRing() {
        let (button, window) = mount(.muted)
        XCTAssertEqual(button.layer?.borderWidth, 0)

        XCTAssertTrue(window.makeFirstResponder(button))

        XCTAssertEqual(button.layer?.borderWidth, 1.5)
        XCTAssertEqual(button.layer?.borderColor, Theme.current.chrome.accent.nsColor.cgColor)
    }
}
