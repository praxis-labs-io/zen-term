import AppKit
import XCTest

@testable import ZenTerm

final class RenameTabOverlayTests: WindowTestCase {
    private var window: NSWindow?
    private var submitted: [String] = []

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDown() {
        window = nil
        submitted = []
        super.tearDown()
    }

    func test_return_submitsTheName() throws {
        let content = try mount()

        XCTAssertTrue(content.performKeyEquivalent(with: try returnKey()))

        XCTAssertEqual(submitted, ["build"])
    }

    func test_returnWhileDismissing_doesNotSubmit() throws {
        let content = try mount()
        let overlay = try XCTUnwrap(content.subviews.compactMap { $0 as? RenameTabOverlay }.first)
        overlay.animateOut {}

        _ = content.performKeyEquivalent(with: try returnKey())

        XCTAssertEqual(submitted, [])
    }

    private func mount() throws -> NSView {
        let overlay = RenameTabOverlay(
            current: "build", liveTitle: "zsh",
            onSubmit: { [weak self] name in self?.submitted.append(name) },
            onCancel: {})
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
