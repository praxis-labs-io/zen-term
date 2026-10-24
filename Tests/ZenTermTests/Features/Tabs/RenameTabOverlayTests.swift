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

    func test_clickingRename_submitsTheTrimmedText() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        overlay.nameFieldForTesting.setText("  api  ")

        try click(overlay.renameButtonForTesting, in: host)

        XCTAssertEqual(submitted, ["api"])
        XCTAssertEqual(cancelCount, 0)
    }

    func test_clickingCancel_cancelsWithoutSubmitting() throws {
        let host = try mount()
        let overlay = try overlay(in: host)

        try click(overlay.cancelButtonForTesting, in: host)

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(submitted, [])
    }

    func test_buttons_areLabelledAndSitAtTheFieldHeight() throws {
        let overlay = try overlay(in: try mount())

        XCTAssertEqual(overlay.renameButtonForTesting.accessibilityLabel(), "Rename")
        XCTAssertEqual(overlay.cancelButtonForTesting.accessibilityLabel(), "Cancel")
        XCTAssertEqual(overlay.renameButtonForTesting.frame.height, overlay.nameFieldForTesting.frame.height)
        XCTAssertEqual(overlay.cancelButtonForTesting.frame.height, overlay.nameFieldForTesting.frame.height)
    }

    func test_tab_fromTheField_reachesCancelThenRename_andBackTabReverses() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        let win = try XCTUnwrap(window)
        overlay.focusInitialResponder()
        let box = overlay.nameFieldForTesting

        _ = box.control(box.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(win.firstResponder === overlay.cancelButtonForTesting)

        try pressKey(keyCode: 48, characters: "\t", in: win)
        XCTAssertTrue(win.firstResponder === overlay.renameButtonForTesting)

        try pressKey(keyCode: 48, characters: "\t", in: win)
        XCTAssertTrue(win.firstResponder === overlay.nameFieldForTesting.field.currentEditor())

        _ = box.control(box.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(win.firstResponder === overlay.renameButtonForTesting)

        try pressKey(keyCode: 123, characters: "\u{F702}", modifiers: [.function, .numericPad], in: win)
        XCTAssertTrue(win.firstResponder === overlay.cancelButtonForTesting)

        try pressKey(keyCode: 124, characters: "\u{F703}", modifiers: [.function, .numericPad], in: win)
        XCTAssertTrue(win.firstResponder === overlay.renameButtonForTesting)

        try pressKey(keyCode: 48, characters: "\u{19}", modifiers: [.shift], in: win)
        XCTAssertTrue(win.firstResponder === overlay.cancelButtonForTesting)
    }

    func test_return_onFocusedCancel_cancels() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        let win = try XCTUnwrap(window)
        XCTAssertTrue(win.makeFirstResponder(overlay.cancelButtonForTesting))

        XCTAssertFalse(host.performKeyEquivalent(with: try returnKey()))
        try pressKey(keyCode: 36, characters: "\r", in: win)

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(submitted, [])
    }

    func test_return_onFocusedRename_submits() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        let win = try XCTUnwrap(window)
        XCTAssertTrue(win.makeFirstResponder(overlay.renameButtonForTesting))

        try pressKey(keyCode: 36, characters: "\r", in: win)

        XCTAssertEqual(submitted, ["build"])
        XCTAssertEqual(cancelCount, 0)
    }

    private func overlay(in host: NSView) throws -> RenameTabOverlay {
        try XCTUnwrap(host.subviews.compactMap { $0 as? RenameTabOverlay }.first)
    }

    private func center(of button: AppButton) -> CGPoint {
        button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    private func click(_ button: AppButton, in host: NSView) throws {
        let point = center(of: button)
        let target = try XCTUnwrap(host.hitTest(host.convert(point, from: nil)))
        XCTAssertTrue(target.isDescendant(of: button), "the click lands on the button")
        try XCTUnwrap(target as? AppButton).performClick(nil)
    }

    private func pressKey(
        keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in win: NSWindow
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: win.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        try XCTUnwrap(win.firstResponder as? NSResponder).keyDown(with: event)
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
