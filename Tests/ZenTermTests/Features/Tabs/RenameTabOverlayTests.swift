import AppKit
import XCTest

@testable import ZenTerm

final class RenameTabOverlayTests: WindowTestCase {
    private var window: NSWindow?
    private var submitted: [String] = []
    private var cancelCount = 0

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDown() {
        window = nil
        submitted = []
        cancelCount = 0
        super.tearDown()
    }

    func test_return_throughTheField_submitsTheName() throws {
        let host = try mount()
        let overlay = try overlay(in: host)

        try sendReturnThroughField(of: overlay)

        XCTAssertEqual(submitted, ["build"])
        XCTAssertFalse(host.performKeyEquivalent(with: try returnKey()), "Return is not a key equivalent")
        XCTAssertEqual(submitted, ["build"])
    }

    func test_returnWhileDismissing_doesNotSubmit() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        overlay.animateOut {}

        try sendReturnThroughField(of: overlay)

        XCTAssertEqual(submitted, [])
    }

    func test_return_submitsTheTrimmedText() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        overlay.nameFieldForTesting.setText("  api  ")

        try sendReturnThroughField(of: overlay)

        XCTAssertEqual(submitted, ["api"])
        XCTAssertEqual(cancelCount, 0)
    }

    func test_escape_cancelsWithoutSubmitting() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        let win = try XCTUnwrap(window)
        XCTAssertTrue(win.makeFirstResponder(overlay.nameFieldForTesting.field))

        XCTAssertTrue(overlay.performKeyEquivalent(with: try escapeKey()))

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(submitted, [])
    }

    func test_footer_isTheLastSection_andNamesReturnAndEscape() throws {
        let overlay = try overlay(in: try mount())

        let footer = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? HintFooter }.first)

        XCTAssertEqual(
            descendants(of: footer).compactMap { ($0 as? NSTextField)?.stringValue }, ["Save", "Cancel"])
        XCTAssertEqual(
            descendants(of: footer).compactMap { $0 as? KeycapView }.map(\.shortcut), ["⏎", "⎋"])
        let inCard = overlay.card.convert(footer.bounds, from: footer)
        XCTAssertEqual(inCard.minX, overlay.card.bounds.minX, "the hairline spans the card edge to edge")
        XCTAssertEqual(inCard.width, overlay.card.bounds.width)
        XCTAssertEqual(inCard.minY, overlay.card.bounds.minY, "nothing sits under it")
        XCTAssertTrue(descendants(of: overlay).compactMap { $0 as? AppButton }.isEmpty, "no buttons")
    }

    func test_reapplyTheme_reachesTheFooter() throws {
        let overlay = try overlay(in: try mount())
        let footer = try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? HintFooter }.first)
        let label = try XCTUnwrap(descendants(of: footer).compactMap { $0 as? NSTextField }.first)
        label.textColor = .red

        overlay.reapplyThemeTree()

        XCTAssertEqual(label.textColor, Theme.current.chrome.ink(.muted))
    }

    private func overlay(in host: NSView) throws -> RenameTabOverlay {
        try XCTUnwrap(host.subviews.compactMap { $0 as? RenameTabOverlay }.first)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func escapeKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53))
    }

    private func sendReturnThroughField(of overlay: RenameTabOverlay) throws {
        let win = try XCTUnwrap(window)
        XCTAssertTrue(win.makeFirstResponder(overlay.nameFieldForTesting.field))
        let editor = try XCTUnwrap(win.firstResponder as? NSTextView, "the field editor is first responder")
        let event = try returnKey()
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: true)
        XCTAssertEqual(try XCTUnwrap(NSApp.currentEvent).keyCode, 36)
        editor.keyDown(with: event)
    }

    private func mount() throws -> NSView {
        let overlay = RenameTabOverlay(
            current: "build", liveTitle: "zsh",
            onSubmit: { [weak self] name in self?.submitted.append(name) },
            onCancel: { [weak self] in self?.cancelCount += 1 })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: win.contentRect(forFrameRect: win.frame))
        win.contentView = host
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        window = win
        return host
    }

    private func returnKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36))
    }
}
