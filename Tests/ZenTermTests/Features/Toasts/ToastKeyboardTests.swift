import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ToastKeyboardTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtInWithStickyCards)
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func toastViews(in controller: WindowController) -> [ToastView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? ToastView }
    }

    private static let characters: [UInt16: String] = [
        36: "\r", 49: " ", 51: "\u{7f}", 53: "\u{1b}",
    ]

    private func keyEvent(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let chars = Self.characters[keyCode] ?? ""
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: keyCode)!
    }

    private enum Key {
        static let returnKey: UInt16 = 36
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func openConfirm(in c: WindowController) {
        c.presentConfirm(
            ConfirmPrompt(
                title: "Close Tab", body: .message("This stops everything running in it."), confirmLabel: "Close"),
            onConfirm: {})
    }

    func test_stickyToast_answersNoKey() throws {
        let c = makeController()
        c.newTabForTesting()
        c.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        settle(0.1)

        let toast = try XCTUnwrap(c.waitingToastForTesting(tabIndex: 0))
        XCTAssertFalse(toast.acceptsFirstResponder, "it never takes focus from the terminal")

        for key in [Key.returnKey, Key.delete, Key.escape, Key.space] {
            XCTAssertFalse(
                toast.performKeyEquivalent(with: keyEvent(key)),
                "a sticky card claims no key, keyCode \(key)")
        }
        XCTAssertEqual(toastViews(in: c).count, 1, "and none of them took it down")
    }

    func test_dismissToast_takesTheOldestAndWalksDown() {
        let c = makeController()
        c.showToast(ToastContent(variant: .info, title: "First", message: "one"))
        c.showToast(ToastContent(variant: .info, title: "Second", message: "two"))
        XCTAssertEqual(toastViews(in: c).count, 2)

        c.handle(.dismissToast)
        settle()

        let left = toastViews(in: c)
        XCTAssertEqual(left.count, 1, "one card down, not both")
        XCTAssertTrue(
            descendants(of: left[0]).compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Second"),
            "the oldest goes first, so repeated presses walk down the stack")

        c.handle(.dismissToast)
        settle()
        XCTAssertTrue(toastViews(in: c).isEmpty)

        c.handle(.dismissToast)
    }

    func test_dismissToast_clearsTheTabAttentionMarker() throws {
        let c = makeController()
        c.newTabForTesting()
        c.notifyAgentForTesting(tabIndex: 0, message: "needs your input")
        settle(0.1)
        XCTAssertNotNil(c.waitingToastForTesting(tabIndex: 0))

        c.handle(.dismissToast)
        settle()

        XCTAssertTrue(toastViews(in: c).isEmpty, "the card comes down")
        XCTAssertNil(
            c.attentionStateForTesting(tabIndex: 0),
            "and the tab stops advertising a notice that is gone")
    }

    func test_dismissAllToasts_clearsTheStack() {
        let c = makeController()
        c.showToast(ToastContent(variant: .info, title: "First", message: "one"))
        c.showToast(ToastContent(variant: .info, title: "Second", message: "two"))
        c.showToast(ToastContent(variant: .info, title: "Third", message: "three"))

        c.handle(.dismissAllToasts)
        settle()

        XCTAssertTrue(toastViews(in: c).isEmpty)
    }

    func test_dismissChords_areRefusedWhileAConfirmIsWaiting() {
        let c = makeController()
        openConfirm(in: c)

        c.handle(.dismissToast)
        c.handle(.dismissAllToasts)
        settle()

        XCTAssertTrue(c.isConfirmOpen, "the confirm is still waiting to be answered")
    }

    func test_dismissChords_workWhileAToolFloatIsOpen() {
        let c = makeController()
        c.showToast(ToastContent(variant: .info, title: "First", message: "one"))
        c.showToast(ToastContent(variant: .info, title: "Second", message: "two"))
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))

        c.handle(.dismissAllToasts)
        settle()

        XCTAssertTrue(toastViews(in: c).isEmpty, "the float must not swallow the dismiss chords")
    }

    func test_dismissChords_leaveACardThatDeclaresNoDismissal() {
        let c = makeController()
        var retried = 0
        var closed = 0
        c.presentSurfaceFailureToastForTesting(retry: { retried += 1 }, close: { closed += 1 })
        XCTAssertEqual(toastViews(in: c).count, 1)

        c.handle(.dismissToast)
        c.handle(.dismissAllToasts)
        settle()

        XCTAssertEqual(toastViews(in: c).count, 1, "the card stays: its exits are Retry and Close")
        XCTAssertEqual(retried, 0, "and neither chord answered it")
        XCTAssertEqual(closed, 0)
    }

    func test_dismissChords_doNotBuildTheStack() {
        let c = makeController()
        XCTAssertFalse(c.hasBuiltToastsForTesting)

        c.handle(.dismissToast)
        c.handle(.dismissAllToasts)

        XCTAssertFalse(c.hasBuiltToastsForTesting)
    }
}
