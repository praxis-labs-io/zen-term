import AppKit
import XCTest

@testable import ZenTerm

final class SettingsOverlayNavTests: WindowTestCase {
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
            onClose: {})
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

    private func mountNav(onReportIssue: @escaping () -> Void) -> (overlay: SettingsOverlay, window: NSWindow) {
        let overlay = SettingsOverlay(
            sections: [BareSection()], capturer: nil,
            onClose: {})
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
        let lastRow = descendants(of: overlay).compactMap { $0 as? NavRow }.last
        win.makeFirstResponder(lastRow)

        lastRow?.onArrowDown?()

        XCTAssertTrue(
            KeyboardFocus.isFocused(reportButton(overlay)!, in: win),
            "Down from the last section row focuses the Report button")
    }

    func test_upFromTheFirstNavRow_staysOnIt() {
        let overlay = SettingsOverlay(sections: [BareSection(), BareSection()], capturer: nil, onClose: {})
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        window = win
        let rows = descendants(of: overlay).compactMap { $0 as? NavRow }
        XCTAssertEqual(rows.count, 2)
        win.makeFirstResponder(rows[0])

        rows[0].keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                isARepeat: false, keyCode: 126)!)

        XCTAssertIdentical(win.firstResponder, rows[0], "Up wrapped from the first section")
    }

    func test_downThroughTheNav_slidesOneFillToTheNextSection() throws {
        Motion.isReduceMotionEnabled = { false }
        let overlay = SettingsOverlay(sections: [BareSection(), BareSection()], capturer: nil, onClose: {})
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        overlay.layoutSubtreeIfNeeded()
        window = win
        let rows = descendants(of: overlay).compactMap { $0 as? NavRow }
        win.makeFirstResponder(rows[0])
        let slide = overlay.navFillSlideForTesting
        waitUntil(slide.slidingRowForTesting(.focus) == nil, "the first row's fill to settle")

        rows[0].keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false, keyCode: 125)!)

        XCTAssertIdentical(win.firstResponder, rows[1], "precondition: Down moves to the next section")
        XCTAssertTrue(slide.isSlidingForTesting(.focus))
        XCTAssertIdentical(slide.slidingRowForTesting(.focus), rows[1])
        XCTAssertFalse(
            slide.isSlidingForTesting(.current), "current and focus move together, so one fill slides, not two")
        XCTAssertEqual(
            rows[1].layer?.backgroundColor?.alpha, 0, "the next section lit up before the slide reached it")
        waitUntil(slide.slidingRowForTesting(.focus) == nil, "the slide to land")
        XCTAssertEqual(rows[1].layer?.backgroundColor, rows[1].restingFill.cgColor)
        XCTAssertGreaterThan(rows[1].layer?.backgroundColor?.alpha ?? 0, 0, "the section it landed on is lit")
        XCTAssertEqual(rows[0].layer?.backgroundColor?.alpha, 0)
    }

    private final class CountingCapturer: KeybindCapturing {
        private(set) var endCount = 0
        func beginCapture(_ handler: @escaping (NSEvent) -> Void) {}
        func endCapture() { endCount += 1 }
    }

    func test_dismissing_endsAnArmedCaptureOnce() {
        let capturer = CountingCapturer()
        let overlay = SettingsOverlay(sections: [BareSection()], capturer: capturer, onClose: {})

        overlay.animateOut {}
        overlay.animateOut {}

        XCTAssertEqual(capturer.endCount, 1)
    }

    private func mount(_ section: SettingsSection, onClose: @escaping () -> Void) -> NSWindow {
        let overlay = SettingsOverlay(
            sections: [section], capturer: nil,
            onClose: onClose)
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
