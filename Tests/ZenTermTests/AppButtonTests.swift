import AppKit
import XCTest

@testable import ZenTerm

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

    func test_focus_stillDrawsTheAccentRing() {
        let (button, window) = mount(.muted)
        XCTAssertEqual(button.layer?.borderWidth, 0)

        XCTAssertTrue(window.makeFirstResponder(button))

        XCTAssertEqual(button.layer?.borderWidth, 1.5)
        XCTAssertEqual(button.layer?.borderColor, Theme.current.chrome.accent.nsColor.cgColor)
    }

    private func mountFitted(_ button: AppButton) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return window
    }

    private func titleFont(_ button: AppButton) -> NSFont? {
        button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    func test_aLargeButton_laysOutTallerWithALargerLabel_andTheStandardSizeIsUnchanged() throws {
        let large = AppButton(title: "Connect", variant: .primary, size: .large)
        let standard = AppButton(title: "Connect", variant: .primary)
        let windows = [try mountFitted(large), try mountFitted(standard)]

        XCTAssertEqual(large.frame.height, 32)
        XCTAssertEqual(titleFont(large)?.pointSize, 13)
        XCTAssertEqual(large.layer?.cornerRadius, 8)
        XCTAssertEqual(standard.frame.height, 26)
        XCTAssertEqual(titleFont(standard)?.pointSize, 12)
        XCTAssertEqual(standard.layer?.cornerRadius, 6)
        withExtendedLifetime(windows) {}
    }
}
