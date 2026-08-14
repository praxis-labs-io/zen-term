import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The keyboard paths into the toast stack: answering a modal confirm, and the two chords that
/// clear notices.
///
/// Every key here is driven as a real event through the window, never by calling an action closure.
/// Nothing covered the confirm's keyboard path before, which is how Return and Esc could ride on
/// `NSButton.keyEquivalent` — a single `performKeyEquivalent` traversal, answered only if it reaches
/// the button — without anything going red.
@MainActor
final class ToastKeyboardTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    // MARK: harness

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        return controller
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func toastViews(in controller: WindowController) -> [ToastView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? ToastView }
    }

    /// The characters macOS actually puts on each of these keys. They have to be real: an
    /// `NSButton` key equivalent matches on `charactersIgnoringModifiers`, so an event carrying ""
    /// would fail the old path for the wrong reason and the falsification would prove nothing.
    private static let characters: [UInt16: String] = [
        36: "\r", 76: "\u{3}", 49: " ", 51: "\u{7f}", 53: "\u{1b}",
    ]

    private func keyEvent(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let chars = Self.characters[keyCode] ?? ""
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: keyCode)!
    }

    /// Press a key the way the window does: the `performKeyEquivalent` sweep of the content view,
    /// then, if nothing claimed it, the first responder's `keyDown`. Driving both is the point —
    /// the confirm has to answer whether or not it still holds focus.
    private func press(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in c: WindowController) {
        let event = keyEvent(keyCode, flags: flags)
        guard let content = c.window.contentView else { return }
        if content.performKeyEquivalent(with: event) { return }
        (c.window.firstResponder as? NSView)?.keyDown(with: event)
    }

    private enum Key {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
    }

    /// Pump the runloop past a spring-out and the stack collapse behind it.
    private func settle(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @discardableResult
    private func openConfirm(
        in c: WindowController, onConfirm: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) -> WindowController {
        c.presentConfirm(
            variant: .warning, title: "Close Tab", message: "This stops everything running in it.",
            confirmLabel: "Close", onConfirm: onConfirm, onCancel: onCancel)
        return c
    }

    // MARK: answering a confirm

    func test_return_confirms() {
        let c = makeController()
        var confirmed = 0
        openConfirm(in: c, onConfirm: { confirmed += 1 })

        press(Key.returnKey, in: c)

        XCTAssertEqual(confirmed, 1, "Return has to answer the confirm")
        XCTAssertFalse(c.isConfirmOpen, "and take the card down")
    }

    /// Caps Lock rides in `modifierFlags` and survives `deviceIndependentFlagsMask`, so anything
    /// answering Return by comparing masks refuses it. Matching on keyCode is what makes this hold.
    func test_return_withCapsLockOn_stillConfirms() {
        let c = makeController()
        var confirmed = 0
        openConfirm(in: c, onConfirm: { confirmed += 1 })

        press(Key.returnKey, flags: .capsLock, in: c)

        XCTAssertEqual(confirmed, 1, "Caps Lock is not a modifier the confirm may refuse")
    }

    /// AppKit tags keypad Enter with `.numericPad` and `.function`, and its character is ETX, not
    /// CR. Both are reasons a character-or-mask comparison misses it; keyCode 76 does not.
    func test_keypadEnter_confirms() {
        let c = makeController()
        var confirmed = 0
        openConfirm(in: c, onConfirm: { confirmed += 1 })

        press(Key.keypadEnter, flags: [.numericPad, .function], in: c)

        XCTAssertEqual(confirmed, 1)
    }

    func test_delete_cancels() {
        let c = makeController()
        var confirmed = 0
        var cancelled = 0
        openConfirm(in: c, onConfirm: { confirmed += 1 }, onCancel: { cancelled += 1 })

        press(Key.delete, in: c)

        XCTAssertEqual(cancelled, 1, "Delete has to cancel")
        XCTAssertEqual(confirmed, 0, "and must never confirm")
        XCTAssertFalse(c.isConfirmOpen)
    }

    func test_escape_cancels() {
        let c = makeController()
        var cancelled = 0
        openConfirm(in: c, onCancel: { cancelled += 1 })

        press(Key.escape, in: c)

        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(c.isConfirmOpen)
    }

    /// The buttons this replaced carried an empty `keyEquivalentModifierMask`, so they answered a
    /// bare Return alone. Matching on keyCode without the same guard let an unbound ⌥⏎ quit the app.
    func test_modifiedReturn_doesNotConfirm() {
        for flags: NSEvent.ModifierFlags in [.option, .command, .control, [.command, .shift]] {
            let c = makeController()
            var confirmed = 0
            openConfirm(in: c, onConfirm: { confirmed += 1 })

            press(Key.returnKey, flags: flags, in: c)

            XCTAssertEqual(confirmed, 0, "a modified Return must not answer (\(flags.rawValue))")
            XCTAssertTrue(c.isConfirmOpen)
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
    }

    func test_modifiedDeleteAndEscape_doNotCancel() {
        let c = makeController()
        var cancelled = 0
        openConfirm(in: c, onCancel: { cancelled += 1 })

        press(Key.delete, flags: .command, in: c)
        press(Key.escape, flags: .option, in: c)

        XCTAssertEqual(cancelled, 0, "a modified Delete or Esc is not the card's key")
        XCTAssertTrue(c.isConfirmOpen)
    }

    /// `KeyboardFocus.key(for:)` folds Space into the same `.activate` as Return. A confirm's
    /// affirmative closes tabs and quits the app, so it takes Return alone.
    func test_space_doesNotConfirm() {
        let c = makeController()
        var confirmed = 0
        var cancelled = 0
        openConfirm(in: c, onConfirm: { confirmed += 1 }, onCancel: { cancelled += 1 })

        press(Key.space, in: c)

        XCTAssertEqual(confirmed, 0, "a Space meant for the buffer must not quit the app")
        XCTAssertEqual(cancelled, 0)
        XCTAssertTrue(c.isConfirmOpen, "and the card is still waiting")
    }

    /// The card stays key-live through its spring-out, so a held Return would answer twice.
    func test_heldReturn_confirmsOnce() {
        let c = makeController()
        var confirmed = 0
        openConfirm(in: c, onConfirm: { confirmed += 1 })

        press(Key.returnKey, in: c)
        press(Key.returnKey, in: c)

        XCTAssertEqual(confirmed, 1)
    }

    // MARK: the sticky contract

    /// A sticky notice is non-modal: it must answer none of these, or a bell card would eat the
    /// Return the shell under it was waiting for.
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

    // MARK: the dismiss chords

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

        c.handle(.dismissToast)  // an empty stack is a no-op, not a crash
    }

    /// The chord answers the card the way its own Dismiss button does, so the tab's colored number
    /// clears with it. Removing the view alone would leave the tab flagged with nothing on screen
    /// explaining why.
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

    /// A confirm swallows every chord, so neither dismiss can pull the question out from under the
    /// answer.
    func test_dismissChords_areRefusedWhileAConfirmIsWaiting() {
        let c = makeController()
        openConfirm(in: c)

        c.handle(.dismissToast)
        c.handle(.dismissAllToasts)
        settle()

        XCTAssertTrue(c.isConfirmOpen, "the confirm is still waiting to be answered")
        XCTAssertEqual(toastViews(in: c).count, 1)
    }

    /// The float gate's `default: return` swallows anything not named in its pass-through list.
    /// Notices stack over an open float, so a chord dead there is dead exactly when the pile grows.
    func test_dismissChords_workWhileAToolFloatIsOpen() {
        let c = makeController()
        c.showToast(ToastContent(variant: .info, title: "First", message: "one"))
        c.showToast(ToastContent(variant: .info, title: "Second", message: "two"))
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))

        c.handle(.dismissAllToasts)
        settle()

        XCTAssertTrue(toastViews(in: c).isEmpty, "the float must not swallow the dismiss chords")
    }

    /// A card's `cancel` button is its negative answer, not a dismissal. The surface-failure notice
    /// offers only Retry and Close Pane, so a chord that took it down would strand a dead pane with
    /// no way to retry and nothing on screen saying why.
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

    /// Dismissing must never be what builds the stack: a window that has shown no notice has no
    /// presenter, and constructing one to clear nothing mounts a view for the life of the window.
    func test_dismissChords_doNotBuildTheStack() {
        let c = makeController()
        XCTAssertFalse(c.hasBuiltToastsForTesting)

        c.handle(.dismissToast)
        c.handle(.dismissAllToasts)

        XCTAssertFalse(c.hasBuiltToastsForTesting)
    }
}
