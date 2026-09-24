import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class ToastPresenterTests: WindowTestCase {
    private func makeHost() -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow = window
        return window.contentView!
    }
    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow = nil
        super.tearDown()
    }

    private func content() -> ToastContent {
        ToastContent(variant: .destructive, title: "Close pane?", message: "It's still running.")
    }

    private func actions() -> [ToastAction] {
        [
            ToastAction(title: "Cancel", kind: .cancel) {},
            ToastAction(title: "Close", kind: .destructive) {},
        ]
    }

    private func buttons(in toast: ToastView) -> [AppButton] {
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        return descendants(of: toast).compactMap { $0 as? AppButton }
    }

    private func arrangedToasts(in host: NSView) -> [ToastView] {
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        return descendants(of: host).compactMap { $0 as? ToastView }
    }

    private func keyEvent(_ keyCode: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)!
    }

    func test_aLongTitle_givesWayBeforeItsTail() throws {
        let host = makeHost()
        let presenter = ToastPresenter(host: host, topInset: 12, trailingInset: 12)
        let tab = "A workspace name long enough to crowd the card"
        let tail = ": bottom drawer"
        let toast = presenter.showSticky(
            ToastContent(variant: .info, title: tab, titleTail: tail, message: "needs you"),
            actions: [ToastAction(title: "Switch", kind: .primary, shortcut: { "⌘\\" }) {}],
            autoDismiss: false)
        host.layoutSubtreeIfNeeded()
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        let labels = descendants(of: toast).compactMap { $0 as? NSTextField }
        let tabLabel = try XCTUnwrap(labels.first { $0.stringValue == tab })
        let tailLabel = try XCTUnwrap(labels.first { $0.stringValue == tail })

        XCTAssertGreaterThanOrEqual(
            tailLabel.frame.width, tailLabel.intrinsicContentSize.width,
            "the drawer name is why the title exists, so it is the part that never clips")
        XCTAssertLessThan(tabLabel.frame.width, tabLabel.intrinsicContentSize.width)
    }

    func test_stickyToast_claimsNeitherReturnNorEsc() {
        let presenter = ToastPresenter(host: makeHost(), topInset: 12, trailingInset: 12)
        let toast = presenter.showSticky(content(), actions: actions())

        XCTAssertFalse(
            toast.performKeyEquivalent(with: keyEvent(36, "\r")),
            "a non-modal sticky toast must not take Return from the terminal")
        XCTAssertFalse(
            toast.performKeyEquivalent(with: keyEvent(53, "\u{1b}")), "nor Esc, which vim wants")
    }

    func test_confirmToast_claimsReturnAndEsc() {
        let presenter = ToastPresenter(host: makeHost(), topInset: 12, trailingInset: 12)
        let toast = presenter.confirm(content(), actions: actions())

        XCTAssertTrue(toast.performKeyEquivalent(with: keyEvent(36, "\r")), "Return answers")
        XCTAssertTrue(toast.performKeyEquivalent(with: keyEvent(53, "\u{1b}")), "and Esc cancels")
    }

    func test_show_mountsToastThenAutoDismisses() {
        let host = makeHost()
        let presenter = ToastPresenter(host: host, topInset: 12, trailingInset: 12, dismissAfter: 0.05)
        presenter.show(content())
        XCTAssertEqual(arrangedToasts(in: host).count, 1, "the toast mounts immediately")

        waitUntil(arrangedToasts(in: host).isEmpty, "the toast to auto-dismiss and be removed")
    }

    func test_aToastRaisedWhereNobodyIsLooking_waitsRatherThanExpiring() {
        let host = makeHost()
        var isPresent = false
        let presenter = ToastPresenter(
            host: host, topInset: 12, trailingInset: 12, dismissAfter: 0.05,
            isPresent: { isPresent })

        presenter.show(content())
        XCTAssertEqual(arrangedToasts(in: host).count, 1, "precondition: it was raised at all")

        let pastTheDuration = Date().addingTimeInterval(0.4)
        while Date() < pastTheDuration {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            arrangedToasts(in: host).count, 1, "well past its duration, and nobody has been there yet")

        isPresent = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        waitUntil(arrangedToasts(in: host).isEmpty, "the countdown to start once you arrive")
    }

    func test_leavingPartWayThroughTheCountdown_handsTheToastBack() {
        let host = makeHost()
        var isPresent = true
        let presenter = ToastPresenter(
            host: host, topInset: 12, trailingInset: 12, dismissAfter: 0.05,
            isPresent: { isPresent })

        presenter.show(content())
        XCTAssertEqual(arrangedToasts(in: host).count, 1, "precondition: it was raised, and counting")

        isPresent = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        let pastTheDuration = Date().addingTimeInterval(0.4)
        while Date() < pastTheDuration {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            arrangedToasts(in: host).count, 1, "you walked away, so it stopped counting where it was")

        isPresent = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        waitUntil(arrangedToasts(in: host).isEmpty, "the countdown to resume once you are back")
    }

    func test_dismiss_isIdempotent_removesExactlyOnce() {
        let host = makeHost()
        let presenter = ToastPresenter(host: host, topInset: 12, trailingInset: 12)
        let toast = presenter.confirm(content(), actions: actions())
        XCTAssertEqual(arrangedToasts(in: host).count, 1)

        presenter.dismiss(toast)
        presenter.dismiss(toast)

        waitUntil(arrangedToasts(in: host).isEmpty, "exactly one removal, no crash on the second dismiss")
    }
}
