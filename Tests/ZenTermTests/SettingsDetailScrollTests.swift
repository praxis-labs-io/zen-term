import AppKit
import XCTest

@testable import ZenTerm

/// Arrow-nav scrolling in the Settings detail pane.
///
/// Two failures live here. `SettingsDetail.moveFocus` revealed the destination stop and nothing else,
/// so arrowing up landed the row's top edge flush against the visible top and left the group caption
/// naming it just off screen — worst at the top of a scrolled section, where the first caption never
/// came back. And it reached its position with `scrollToVisible` calls, which snap: held at key-repeat
/// speed, each step jumped a different distance (35pt between rows, 66 across a group boundary).
///
/// The destinations are asserted under Reduce Motion, where the glide lands immediately. How the glide
/// itself reads is the runbook's, not a test's; what a test can check is that it does not snap, and
/// that a burst of keystrokes aims at the same place the instant path lands on.
final class SettingsDetailScrollTests: WindowTestCase {
    private var tempRoot: URL!
    private var window: NSWindow?
    private var section: SettingsKeybindsSection?
    private var originalReduceMotion: (() -> Bool)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-detail-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        try "".write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
        originalReduceMotion = Motion.isReduceMotionEnabled
        Motion.isReduceMotionEnabled = { true }  // land on each position, so a destination is readable
    }

    override func tearDownWithError() throws {
        Motion.isReduceMotionEnabled = originalReduceMotion
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
    private func mountKeybinds() -> SettingsScrollView {
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
        return detail as! SettingsScrollView  // swiftlint:disable:this force_cast
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

    // MARK: the glide

    /// A burst of keystrokes aims at one position and eases toward it. Measuring each step from the
    /// live position instead of the pending one leaves a held arrow short of where it aimed, which is
    /// the same stutter in a different shape. Whether the glide *arrives* rides on a display link, so
    /// that part is the runbook's: a test that waits on one is a test that fails on a machine with no
    /// display attached.
    func test_aBurstOfKeystrokes_aimsWhereTheInstantPathLands() {
        let instant = mountKeybinds()
        let instantChips = descendants(of: instant).compactMap { $0 as? KeybindChip }
        window!.makeFirstResponder(instantChips[0])
        press(Self.downKey, times: 12)
        let landed = instant.documentVisibleRect.minY
        XCTAssertGreaterThan(landed, 0, "the instant path scrolled somewhere to compare against")

        Motion.isReduceMotionEnabled = { false }
        let glided = mountKeybinds()
        let chips = descendants(of: glided).compactMap { $0 as? KeybindChip }
        window!.makeFirstResponder(chips[0])
        press(Self.downKey, times: 12)

        XCTAssertEqual(glided.pendingTop, landed, accuracy: 0.5, "the burst aims at the same position")
        XCTAssertLessThan(
            glided.documentVisibleRect.minY, landed, "the content eases toward it rather than snapping")
    }

    /// A held arrow repeats faster than the glide settles, so the content is behind where the last
    /// keystroke aimed. The focused row rode that lag off the top or bottom edge until the glide caught
    /// up. Nothing is pumped here on purpose: with no frame ticking at all, the content only moves by
    /// the catch-up the keystroke itself does, which is the worst case a held arrow can produce.
    func test_holdingAnArrow_keepsTheFocusedRowOnScreen() throws {
        Motion.isReduceMotionEnabled = { false }
        let scroll = mountKeybinds()
        let chips = descendants(of: scroll).compactMap { $0 as? KeybindChip }
        let rows = descendants(of: scroll).compactMap { $0 as? KeybindRow }

        window!.makeFirstResponder(chips[0])
        for key in [Self.downKey, Self.upKey] {
            for step in 0..<chips.count {
                press(key, times: 1)
                let responder = try XCTUnwrap(window!.firstResponder as? NSView)
                // The stop the reader is looking at: a chip's row (Reset-all is its own stop).
                let focused = rows.first { $0.chip === responder } ?? responder
                XCTAssertTrue(
                    isFullyVisible(focused, in: scroll),
                    "step \(step) of \(key == Self.downKey ? "Down" : "Up") left the focused stop off screen")
            }
        }
    }
}
