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

    private func mountFilled(onTap: @escaping () -> Void = {}) throws -> (AppButton, NSWindow, KeycapView) {
        let button = AppButton(title: "Connect", variant: .filled, shortcut: "⏎", onTap: onTap)
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
        return (button, window, try XCTUnwrap(button.keycapForTesting))
    }

    func test_aClickOnAFilledButtonsKeycap_reachesTheButton() throws {
        var taps = 0
        let (button, window, keycap) = try mountFilled { taps += 1 }
        let content = try XCTUnwrap(window.contentView)
        let onKeycap = keycap.convert(NSPoint(x: keycap.bounds.midX, y: keycap.bounds.midY), to: content)

        let hit = content.hitTest(onKeycap)
        XCTAssertTrue(hit === button, "the keycap must not swallow the click")
        (hit as? NSButton)?.performClick(nil)

        XCTAssertEqual(taps, 1)
    }

    func test_aFilledButtonsKeycap_sitsInsideIt() throws {
        let (button, _, keycap) = try mountFilled()

        XCTAssertTrue(button.bounds.contains(keycap.frame), "the keycap is clipped by the button")
        XCTAssertEqual(button.title, "Connect")
    }

    func test_aFilledButton_isSolidAccent_withItsKeycapInverted() throws {
        let (button, _, keycap) = try mountFilled()
        let chrome = Theme.current.chrome

        XCTAssertEqual(button.layer?.backgroundColor, chrome.accent.nsColor.cgColor)
        XCTAssertEqual(titleColor(button), chrome.background.nsColor)
        XCTAssertEqual(keycap.tone, .inverse)
        XCTAssertEqual(keycap.layer?.backgroundColor, KeycapView.Tone.inverse.fill.cgColor)
    }

    func test_aDisabledFilledButton_dropsItsKeycapsInverseTone() throws {
        let (button, _, keycap) = try mountFilled()

        button.isEnabled = false

        XCTAssertEqual(keycap.tone, .plain, "an inverse keycap on the disabled fill reads as a dark smudge")
        XCTAssertEqual(keycap.layer?.backgroundColor, KeycapView.Tone.plain.fill.cgColor)
        button.isEnabled = true
        XCTAssertEqual(keycap.tone, .inverse)
    }
}
