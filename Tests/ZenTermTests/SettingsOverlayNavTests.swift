import AppKit
import XCTest

@testable import ZenTerm

/// Regression guard for the Settings nav column's background (ZEN-136 follow-up). The nav rows
/// scroll inside an `NSScrollView`, and `drawsBackground` FORWARDS to the scroll view's current
/// clip view — so installing the flipped clip view after clearing the flag silently resurrected
/// the default opaque system background: an appearance-following wash over the whole column that
/// ignores `Theme.current` (ZEN-27) and reads as a mismatched sidebar panel.
final class SettingsOverlayNavTests: XCTestCase {
    /// Retained so a mounted card's window outlives the mount call (Esc is dispatched through it).
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private final class BareSection: SettingsSection {
        let navTitle = "Test"
        var onExitToNav: (() -> Void)?
        func makeDetailView() -> NSView { NSView() }
        func detailStops() -> [NSView] { [] }
        func sectionWillHide() {}
        func reapplyTheme() {}
    }

    /// A section whose single detail stop is a real `Dropdown` — the `PopoverHosting` adopter, so
    /// Esc layering can be driven through the Settings card (ZEN-149).
    private final class DropdownSection: SettingsSection {
        let navTitle = "Picker"
        var onExitToNav: (() -> Void)?
        let dropdown = Dropdown(
            items: [DropdownItem(title: "One", group: nil, note: nil, isSelected: true)],
            selectedIndex: 0, onChange: { _ in })
        func makeDetailView() -> NSView {
            let host = NSView()
            dropdown.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(dropdown)
            return host
        }
        func detailStops() -> [NSView] { [dropdown] }
        func sectionWillHide() {}
        func reapplyTheme() {}
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func test_navScroll_keepsTheCardBackground_notAnOpaqueClipViewWash() {
        let overlay = SettingsOverlay(
            sections: [BareSection()], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)

        let scrolls = descendants(of: overlay).compactMap { $0 as? NSScrollView }
        guard let navScroll = scrolls.first(where: { $0.contentView is FlippedClipView }) else {
            return XCTFail("expected the nav's scroll view with its flipped clip view installed")
        }
        XCTAssertFalse(
            navScroll.drawsBackground,
            "the nav scroll must not paint its own background — the flag forwards to the CURRENT "
                + "clip view, so it must be cleared after FlippedClipView is installed, not before")
        XCTAssertFalse(
            navScroll.contentView.drawsBackground,
            "the installed clip view itself must not draw — an opaque clip view is the exact "
                + "appearance-following sidebar wash this test guards against")
    }

    // MARK: Esc (ZEN-149)

    private func mount(_ section: SettingsSection, onClose: @escaping () -> Void) -> NSWindow {
        let overlay = SettingsOverlay(
            sections: [section], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: onClose)
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        self.window = window
        return window
    }

    @discardableResult
    private func pressEscape(in window: NSWindow) -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window.contentView!.performKeyEquivalent(with: esc)
    }

    func test_escape_fromNavRow_closesTheCard() {
        var closed = 0
        let window = mount(BareSection(), onClose: { closed += 1 })

        XCTAssertTrue(pressEscape(in: window), "the card root must claim Esc")

        XCTAssertEqual(closed, 1)
    }

    /// Layering, driven through the Settings card: an open dropdown takes the first Esc, the card
    /// takes the second. `Dropdown` only ever got this right by accident before — Settings happens
    /// to have no Esc key equivalent — and the identical `IconPickerField` code was unreachable.
    func test_escape_withDropdownOpen_closesTheListFirst_thenTheCard() {
        var closed = 0
        let section = DropdownSection()
        let window = mount(section, onClose: { closed += 1 })
        window.makeFirstResponder(section.dropdown)
        section.dropdown.openListForTesting()
        XCTAssertTrue(section.dropdown.isPopoverOpen)

        pressEscape(in: window)

        XCTAssertFalse(section.dropdown.isPopoverOpen, "the first Esc closes the list")
        XCTAssertEqual(closed, 0, "the first Esc must NOT close the card")

        pressEscape(in: window)

        XCTAssertEqual(closed, 1, "the second Esc closes the card")
    }
}
