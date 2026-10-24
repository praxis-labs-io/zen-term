import AppKit
import XCTest

@testable import ZenTerm

final class ModalShellTests: WindowTestCase {
    private final class Sink {
        var cancelled = 0
        var dismissed = 0
        var cancelOverrides = 0
    }

    private final class TestShell: ModalShell {
        var overlaid = false
        var busy = false
        var onCancelOverride: (() -> Void)?

        override var isShowingOverlaidCard: Bool { overlaid }
        override var isBusy: Bool { busy }

        override func cancel() {
            if let onCancelOverride {
                onCancelOverride()
                return
            }
            super.cancel()
        }
    }

    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    func test_escWhileDismissing_isNotClaimed() throws {
        let (shell, sink) = mount()
        shell.animateOut {}

        XCTAssertFalse(shell.performKeyEquivalent(with: try escapeKey()))
        XCTAssertEqual(sink.cancelled, 0)
    }

    func test_aClickWhileDismissing_fallsThrough() throws {
        let (shell, _) = mount()
        let content = try XCTUnwrap(window?.contentView)
        let center = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        XCTAssertTrue(try XCTUnwrap(content.hitTest(center)).isDescendant(of: shell))

        shell.animateOut {}

        XCTAssertFalse(try XCTUnwrap(content.hitTest(center)).isDescendant(of: shell))
    }

    func test_escWhileShowingAnOverlaidCard_isLeftToTheCardOnTop() throws {
        let (shell, sink) = mount()
        shell.overlaid = true

        XCTAssertFalse(shell.performKeyEquivalent(with: try escapeKey()))
        XCTAssertEqual(sink.cancelled, 0)
    }

    func test_whileBusy_escAndBackdropDoNothing() throws {
        let (shell, sink) = mount(withOnDismiss: true)
        shell.busy = true

        _ = shell.performKeyEquivalent(with: try escapeKey())
        try XCTUnwrap(backdrop(in: shell)).mouseDown(with: NSEvent())

        XCTAssertEqual(sink.cancelled, 0)
        XCTAssertEqual(sink.dismissed, 0)
    }

    func test_withOnDismiss_backdropDismisses_andEscCancels() throws {
        let (shell, sink) = mount(withOnDismiss: true)

        try XCTUnwrap(backdrop(in: shell)).mouseDown(with: NSEvent())
        XCTAssertEqual(sink.dismissed, 1)
        XCTAssertEqual(sink.cancelled, 0)

        XCTAssertTrue(shell.performKeyEquivalent(with: try escapeKey()))
        XCTAssertEqual(sink.cancelled, 1)
        XCTAssertEqual(sink.dismissed, 1)
    }

    func test_withoutOnDismiss_backdropCancels() throws {
        let (shell, sink) = mount()

        try XCTUnwrap(backdrop(in: shell)).mouseDown(with: NSEvent())

        XCTAssertEqual(sink.cancelled, 1)
    }

    func test_aSubclassOverridingCancel_getsEsc() throws {
        let (shell, sink) = mount()
        shell.onCancelOverride = { sink.cancelOverrides += 1 }

        XCTAssertTrue(shell.performKeyEquivalent(with: try escapeKey()))

        XCTAssertEqual(sink.cancelOverrides, 1)
        XCTAssertEqual(sink.cancelled, 0)
    }

    private func mount(withOnDismiss: Bool = false) -> (shell: TestShell, sink: Sink) {
        let sink = Sink()
        let shell = TestShell(
            width: 300, onCancel: { sink.cancelled += 1 },
            onDismiss: withOnDismiss ? { sink.dismissed += 1 } : nil)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: win.contentRect(forFrameRect: win.frame))
        win.contentView = host
        host.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shell.topAnchor.constraint(equalTo: host.topAnchor),
            shell.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        window = win
        return (shell, sink)
    }

    private func backdrop(in shell: NSView) -> BackdropView? {
        shell.subviews.compactMap { $0 as? BackdropView }.first
    }

    private func escapeKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
    }
}
