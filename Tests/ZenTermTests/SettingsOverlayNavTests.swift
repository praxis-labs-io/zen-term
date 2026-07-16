import AppKit
import XCTest

@testable import ZenTerm

/// Regression guard for the Settings nav column's background (ZEN-136 follow-up). The nav rows
/// scroll inside an `NSScrollView`, and `drawsBackground` FORWARDS to the scroll view's current
/// clip view — so installing the flipped clip view after clearing the flag silently resurrected
/// the default opaque system background: an appearance-following wash over the whole column that
/// ignores `Theme.current` (ZEN-27) and reads as a mismatched sidebar panel.
final class SettingsOverlayNavTests: XCTestCase {
    private final class BareSection: SettingsSection {
        let navTitle = "Test"
        var onExitToNav: (() -> Void)?
        var onClose: (() -> Void)?
        func makeDetailView() -> NSView { NSView() }
        func detailStops() -> [NSView] { [] }
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
}
