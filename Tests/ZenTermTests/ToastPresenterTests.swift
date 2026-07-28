import AppKit
import XCTest

@testable import ZenTerm

/// Coverage for `ToastPresenter`'s lifecycle + the "sticky toast never steals input" guarantee
/// (ZEN-106). The key-equivalent assertions matter: a sticky/passive toast that armed Return/Esc
/// would hijack those keys from the focused terminal.
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

    // MARK: key-equivalent guarantee

    func test_stickyToast_armsNoReturnOrEscKeyEquivalents() {
        let presenter = ToastPresenter(host: makeHost(), topInset: 12, trailingInset: 12)
        let toast = presenter.showSticky(content(), actions: actions())
        let armed = buttons(in: toast).map(\.keyEquivalent)
        XCTAssertEqual(armed, ["", ""], "a non-modal sticky toast must not hijack Return/Esc from the terminal")
    }

    func test_confirmToast_armsKeyEquivalents() {
        let presenter = ToastPresenter(host: makeHost(), topInset: 12, trailingInset: 12)
        let toast = presenter.confirm(content(), actions: actions())
        let armed = Set(buttons(in: toast).map(\.keyEquivalent))
        XCTAssertTrue(armed.contains("\r"), "the destructive action arms Return")
        XCTAssertTrue(armed.contains("\u{1b}"), "the cancel action arms Esc")
    }

    // MARK: lifecycle

    func test_show_mountsToastThenAutoDismisses() {
        let host = makeHost()
        let presenter = ToastPresenter(host: host, topInset: 12, trailingInset: 12, dismissAfter: 0.05)
        presenter.show(content())
        XCTAssertEqual(arrangedToasts(in: host).count, 1, "the toast mounts immediately")

        waitUntil(arrangedToasts(in: host).isEmpty, "the toast to auto-dismiss and be removed")
    }

    func test_dismiss_isIdempotent_removesExactlyOnce() {
        let host = makeHost()
        let presenter = ToastPresenter(host: host, topInset: 12, trailingInset: 12)
        let toast = presenter.confirm(content(), actions: actions())
        XCTAssertEqual(arrangedToasts(in: host).count, 1)

        // A user click and the auto-dismiss timer can both fire — dismiss must not double-remove.
        presenter.dismiss(toast)
        presenter.dismiss(toast)

        waitUntil(arrangedToasts(in: host).isEmpty, "exactly one removal, no crash on the second dismiss")
    }
}
