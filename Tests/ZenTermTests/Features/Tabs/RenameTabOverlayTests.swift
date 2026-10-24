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

        try click(overlay.saveButtonForTesting, in: host)

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

    func test_pressOnRename_releasedOutside_doesNothing() throws {
        let host = try mount()
        let overlay = try overlay(in: host)
        let button = overlay.saveButtonForTesting
        let inside = center(of: button)

        button.mouseDown(with: try mouse(.leftMouseDown, at: inside))
        button.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 2, y: 2)))

        XCTAssertEqual(submitted, [])
        XCTAssertEqual(cancelCount, 0)
    }

    func test_buttons_areLabelledAndSquareAtTheFieldHeight() throws {
        let overlay = try overlay(in: try mount())

        XCTAssertEqual(overlay.saveButtonForTesting.tooltipLabelForTesting, "Rename")
        XCTAssertEqual(overlay.cancelButtonForTesting.tooltipLabelForTesting, "Cancel")
        XCTAssertEqual(overlay.saveButtonForTesting.frame.size, overlay.cancelButtonForTesting.frame.size)
        XCTAssertEqual(overlay.saveButtonForTesting.frame.height, overlay.nameFieldForTesting.frame.height)
    }

    private func overlay(in host: NSView) throws -> RenameTabOverlay {
        try XCTUnwrap(host.subviews.compactMap { $0 as? RenameTabOverlay }.first)
    }

    private func center(of button: IconButton) -> CGPoint {
        button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    private func click(_ button: IconButton, in host: NSView) throws {
        let point = center(of: button)
        let target = try XCTUnwrap(host.hitTest(host.convert(point, from: nil)))
        XCTAssertTrue(target.isDescendant(of: button), "the click lands on the button")
        button.mouseDown(with: try mouse(.leftMouseDown, at: point))
        button.mouseUp(with: try mouse(.leftMouseUp, at: point))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: try XCTUnwrap(window).windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }

    private func sendReturnThroughField(of overlay: RenameTabOverlay) throws {
        let event = try returnKey()
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: true)
        XCTAssertEqual(try XCTUnwrap(NSApp.currentEvent).keyCode, 36)
        let box = overlay.nameFieldForTesting
        _ = box.control(box.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
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
