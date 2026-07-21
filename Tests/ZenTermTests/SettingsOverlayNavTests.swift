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

    /// A section whose single detail stop is a real `Dropdown`.
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

    // MARK: Report an Issue button (ZEN-212)

    private func mountNav(onReportIssue: @escaping () -> Void) -> (overlay: SettingsOverlay, window: NSWindow) {
        let overlay = SettingsOverlay(
            sections: [BareSection()], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        overlay.onReportIssue = onReportIssue
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        window = win
        return (overlay, win)
    }

    private func reportButton(_ overlay: NSView) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == "Report an Issue" }
    }

    func test_reportButton_firesOnReportIssue() {
        var reported = 0
        let (overlay, _) = mountNav(onReportIssue: { reported += 1 })

        reportButton(overlay)?.onTap()

        XCTAssertEqual(reported, 1, "tapping the nav's Report button opens the composer")
    }

    func test_downFromLastNavRow_reachesReportButton() {
        let (overlay, win) = mountNav(onReportIssue: {})
        let lastRow = descendants(of: overlay).compactMap { $0 as? SettingsNavRow }.last
        win.makeFirstResponder(lastRow)

        lastRow?.onArrowDown?()

        XCTAssertTrue(
            KeyboardFocus.isFocused(reportButton(overlay)!, in: win),
            "Down from the last section row focuses the Report button")
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

}
