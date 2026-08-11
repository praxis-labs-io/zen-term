import AppKit
import XCTest

@testable import ZenTerm

/// Arrow-nav scrolling in the Settings detail pane. `SettingsDetail.moveFocus` revealed the destination
/// stop and nothing else, so a step landed the row hard against the edge it arrived at: arrowing up put
/// its top flush with the visible top and left the group caption naming it just off screen, worst at the
/// top of a scrolled section where the first caption never came back.
///
/// These mount the real section in a window short enough to scroll and drive real arrow events at the
/// chips. A state-only check on the focused index passes with the row off screen entirely.
final class SettingsDetailScrollTests: WindowTestCase {
    private var tempRoot: URL!
    private var window: NSWindow?
    private var section: SettingsKeybindsSection?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-detail-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        try "".write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        window = nil
        section = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: harness

    /// The Keybinds section in a 380pt-tall window: several groups of chips, well past what fits, so
    /// every arrow step has somewhere to scroll.
    private func mountKeybinds() -> NSScrollView {
        let section = SettingsKeybindsSection(capturer: nil)
        self.section = section
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = win.contentView!
        content.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: content.topAnchor),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        window = win
        return detail as! NSScrollView  // swiftlint:disable:this force_cast
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// An arrow as AppKit delivers one: the `.function`/`.numericPad` pair rides on every arrow
    /// keyDown, and a bare-modifier fake is a keystroke macOS never sends.
    private func arrow(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }
    private static let upKey: UInt16 = 126
    private static let downKey: UInt16 = 125

    /// Send `count` arrows to whatever holds focus, re-reading the first responder each step so the
    /// walk follows focus through the section the way a held key does.
    private func press(_ keyCode: UInt16, times count: Int) {
        for _ in 0..<count {
            guard let responder = window?.firstResponder as? NSView else { return }
            responder.keyDown(with: arrow(keyCode))
        }
    }

    /// The group captions, in order: a caption is a plain label arranged in the rows stack, next to
    /// the `KeybindRow`s and the trailing Reset-all rows.
    private func captions(in scroll: NSScrollView) -> [NSTextField] {
        let stack = scroll.documentView?.subviews.compactMap { $0 as? NSStackView }.first
        return stack?.arrangedSubviews.compactMap { $0 as? NSTextField } ?? []
    }

    private func isFullyVisible(_ view: NSView, in scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        return scroll.documentVisibleRect.contains(view.convert(view.bounds, to: document))
    }

    // MARK: what a step reveals

    func test_arrowingUpToTheFirstRow_bringsBackTheFirstGroupCaption() throws {
        let scroll = mountKeybinds()
        let chips = descendants(of: scroll).compactMap { $0 as? KeybindChip }
        XCTAssertGreaterThan(chips.count, 12, "expected a section taller than the window")
        let caption = try XCTUnwrap(captions(in: scroll).first)

        window!.makeFirstResponder(chips[0])
        press(Self.downKey, times: 12)
        XCTAssertFalse(isFullyVisible(caption, in: scroll), "the section has to be scrolled first")

        press(Self.upKey, times: 12)

        XCTAssertIdentical(window!.firstResponder, chips[0], "Up clamps at the first chip")
        XCTAssertTrue(
            isFullyVisible(caption, in: scroll),
            "focusing the first row shows the caption above it, not just the row")
        XCTAssertEqual(
            scroll.documentVisibleRect.minY, 0, accuracy: 0.5, "the first stop opens at the very top")
    }

    func test_arrowingUpToAGroupsFirstRow_bringsBackThatGroupsCaption() throws {
        let scroll = mountKeybinds()
        let chips = descendants(of: scroll).compactMap { $0 as? KeybindChip }
        let caption = try XCTUnwrap(captions(in: scroll).dropFirst().first, "expected several groups")
        let firstOfGroup = try XCTUnwrap(firstChip(below: caption, among: chips))
        let index = try XCTUnwrap(chips.firstIndex(of: firstOfGroup))

        window!.makeFirstResponder(chips[chips.count - 1])
        press(Self.upKey, times: chips.count - 1 - index)

        XCTAssertIdentical(window!.firstResponder, firstOfGroup, "landed on the group's first chip")
        XCTAssertTrue(
            isFullyVisible(caption, in: scroll),
            "arrowing up into a group shows the caption that names it")
    }

    /// The first chip below `caption` in document order — the row the caption heads.
    private func firstChip(below caption: NSTextField, among chips: [KeybindChip]) -> KeybindChip? {
        guard let document = caption.superview?.superview else { return nil }
        let captionBottom = caption.convert(caption.bounds, to: document).maxY
        return chips.first { $0.convert($0.bounds, to: document).minY >= captionBottom }
    }

    // MARK: room around the focused row

    /// The reveal aims past the edge the row arrives at. Landing it flush there is legible but reads as
    /// scraping the pane edge, and it was what left the caption above a row off screen.
    func test_walkingDown_leavesRoomBelowTheFocusedRow() throws {
        let scroll = mountKeybinds()
        let chips = descendants(of: scroll).compactMap { $0 as? KeybindChip }
        let rows = descendants(of: scroll).compactMap { $0 as? KeybindRow }

        window!.makeFirstResponder(chips[0])
        press(Self.downKey, times: 12)

        let focused = try XCTUnwrap(rows.first { $0.chip === window!.firstResponder })
        let document = try XCTUnwrap(scroll.documentView)
        let gap = scroll.documentVisibleRect.maxY - focused.convert(focused.bounds, to: document).maxY
        XCTAssertGreaterThan(gap, 24, "the row it scrolled to keeps room below it, not just its padding")
    }

    /// The reveal's up rule was gated on the strip above the stop rather than on the stop itself, so a
    /// Down step onto a row already in view could pull the list backwards by as much as the margin.
    func test_arrowingDownOntoAVisibleRow_neverScrollsBackwards() throws {
        let scroll = mountKeybinds()
        let chips = descendants(of: scroll).compactMap { $0 as? KeybindChip }

        // Hand-scroll mid-list, then focus a chip sitting near the top of the pane, the state a mouse
        // user lands in before reaching for the arrows.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        let document = try XCTUnwrap(scroll.documentView)
        let nearTop = try XCTUnwrap(
            chips.first { $0.convert($0.bounds, to: document).minY > scroll.documentVisibleRect.minY })
        window!.makeFirstResponder(nearTop)
        let before = scroll.documentVisibleRect.minY

        press(Self.downKey, times: 1)

        XCTAssertGreaterThanOrEqual(
            scroll.documentVisibleRect.minY, before,
            "a step that moves focus down must not move the list up")
    }

    /// A held arrow has to hold the focused row at a steady place in the pane while the list moves under
    /// it. Firing the up rule only once the row had already left the viewport let it climb several rows
    /// and then threw it back by the whole margin, which reads as the selection bouncing around the top.
    func test_walkingUp_keepsTheFocusedRowAtASteadyOffset() throws {
        let scroll = mountKeybinds()
        let chips = descendants(of: scroll).compactMap { $0 as? KeybindChip }
        let rows = descendants(of: scroll).compactMap { $0 as? KeybindRow }
        let document = try XCTUnwrap(scroll.documentView)

        window!.makeFirstResponder(chips[chips.count - 1])
        var offsets: [CGFloat] = []
        for _ in 0..<12 {
            press(Self.upKey, times: 1)
            guard let focused = rows.first(where: { $0.chip === window!.firstResponder }) else { continue }
            let top = focused.convert(focused.bounds, to: document).minY
            offsets.append(top - scroll.documentVisibleRect.minY)
        }

        // Only the steps that actually scroll: the first few move focus up through rows already on
        // screen, where the list correctly stays put.
        let scrolling = offsets.suffix(6)
        let spread = try XCTUnwrap(scrolling.max()) - (try XCTUnwrap(scrolling.min()))
        XCTAssertLessThan(
            spread, 40,
            "the row's place in the pane wandered by \(Int(spread))pt across six steps: \(scrolling)")
    }

    /// Direction gating decides which edge a step aims at, but the stop still has to be on screen either
    /// way. Gated on direction alone, a Down step onto a row above a hand-scrolled viewport moved
    /// nothing: focus advanced off the top of the pane and Return would have fired a row nobody could
    /// see.
    func test_arrowingDownOntoARowAboveTheViewport_bringsItBack() throws {
        let scroll = mountKeybinds()
        let chips = descendants(of: scroll).compactMap { $0 as? KeybindChip }
        let rows = descendants(of: scroll).compactMap { $0 as? KeybindRow }
        let document = try XCTUnwrap(scroll.documentView)

        // Focus near the top, then hand-scroll far past it, as a trackpad would.
        window!.makeFirstResponder(chips[1])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertFalse(
            scroll.documentVisibleRect.intersects(chips[1].convert(chips[1].bounds, to: document)),
            "premise: the focused row is off the top of the pane")

        press(Self.downKey, times: 1)

        let focused = try XCTUnwrap(rows.first { $0.chip === window!.firstResponder })
        XCTAssertTrue(
            scroll.documentVisibleRect.contains(focused.convert(focused.bounds, to: document)),
            "the row focus moved to has to be on screen, whichever edge it came from")
    }
}
