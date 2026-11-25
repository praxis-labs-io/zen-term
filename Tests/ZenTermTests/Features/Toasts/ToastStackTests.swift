import AppKit
import XCTest

@testable import ZenTerm

private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
final class ToastStackTests: WindowTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { true }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.orderFront(nil)
    }

    override func tearDownWithError() throws {
        window = nil
        try super.tearDownWithError()
    }

    private func presenter(dismissAfter: TimeInterval = 60) -> ToastPresenter {
        ToastPresenter(host: window.contentView!, topInset: 12, trailingInset: 12, dismissAfter: dismissAfter)
    }

    private func notice(_ title: String) -> ToastContent {
        ToastContent(variant: .info, title: title, message: "Something happened.")
    }

    private func toast(titled title: String) -> ToastView? {
        descendants(of: window.contentView!).compactMap { $0 as? ToastView }.first { toast in
            descendants(of: toast).contains { ($0 as? NSTextField)?.stringValue == title }
        }
    }

    private func showThree(on presenter: ToastPresenter) {
        for title in ["First", "Second", "Third"] { presenter.show(notice(title)) }
        window.contentView!.layoutSubtreeIfNeeded()
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // The release is queued first: a button's tracking loop pulls it from the queue inside the press.
    private func click(at point: NSPoint) {
        NSApp.postEvent(mouse(.leftMouseUp, at: point), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown, at: point))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
        }
    }

    private func click(_ view: NSView) {
        click(at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }

    private func letTimePass(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func visible(_ title: String, in pile: ToastPile) -> Bool {
        guard let toast = toast(titled: title) else { return false }
        return pile.opacityForTesting(toast) == 1
    }

    func test_threeToasts_foldBehindTheNewest() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        let front = try XCTUnwrap(toast(titled: "Third"))

        XCTAssertFalse(pile.isUnfolded)
        XCTAssertTrue(visible("Third", in: pile), "the newest sits in front")
        XCTAssertFalse(visible("Second", in: pile), "older toasts stay folded behind it")
        XCTAssertFalse(visible("First", in: pile))
        XCTAssertEqual(pile.plateOpacityForTesting, [0.75, 0.45], "two cards recede behind the front one")
        XCTAssertEqual(
            pile.frame.height, front.frame.height + 2 * ChromeMetrics.Spacing.s12,
            "the folded stack is one card tall plus the receding edges")
    }

    func test_clickingTheFoldedStack_unfoldsItAndHoldsTheCountdowns() throws {
        let presenter = presenter(dismissAfter: 0.1)
        showThree(on: presenter)
        let pile = presenter.pileForTesting

        click(try XCTUnwrap(toast(titled: "Third")))

        XCTAssertTrue(pile.isUnfolded, "a click on the front card unfolds the stack")
        XCTAssertTrue(["First", "Second", "Third"].allSatisfy { visible($0, in: pile) })
        XCTAssertNotNil(toast(titled: "Third"), "the click unfolded rather than dismissing the front toast")
        presenter.show(notice("Fourth"))
        letTimePass(0.4)
        XCTAssertEqual(
            descendants(of: pile).compactMap { $0 as? ToastView }.count, 4,
            "well past the duration, nothing expires while the stack is open")
    }

    func test_clickingTheFrontToastsTitle_unfoldsRatherThanDismissing() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let front = try XCTUnwrap(toast(titled: "Third"))
        let title = try XCTUnwrap(descendants(of: front).first { ($0 as? NSTextField)?.stringValue == "Third" })

        click(title)

        XCTAssertTrue(presenter.pileForTesting.isUnfolded)
        XCTAssertNotNil(toast(titled: "Third"), "the click on the text did not dismiss the toast")
    }

    func test_aClickBesideANarrowFrontCard_reachesWhatIsBehindTheStack() throws {
        let behind = ClickCatcher(frame: window.contentView!.bounds)
        window.contentView!.addSubview(behind)
        let presenter = presenter()
        presenter.show(notice("A notice wide enough to set the stack's width"))
        let readout = FontSizeCard(text: "13 pt")
        presenter.present(card: readout)
        window.contentView!.layoutSubtreeIfNeeded()
        let pile = presenter.pileForTesting
        XCTAssertLessThan(readout.frame.width, pile.frame.width, "precondition: the hidden toast widens the stack")

        click(at: pile.convert(NSPoint(x: pile.bounds.minX + 4, y: readout.frame.midY), to: nil))

        XCTAssertTrue(behind.clicked, "the click beside the front card reaches the view behind")
        XCTAssertFalse(pile.isUnfolded)
    }

    func test_anUpdatedCard_comesBackInFrontOfNewerToasts() {
        let presenter = presenter()
        let readout = FontSizeCard(text: "13 pt")
        presenter.present(card: readout)
        presenter.show(notice("Config reloaded"))
        let pile = presenter.pileForTesting
        XCTAssertFalse(pile.isShowing(readout), "precondition: folded behind the newer toast")

        presenter.bringForward(card: readout)

        XCTAssertTrue(pile.front === readout)
        XCTAssertEqual(pile.opacityForTesting(readout), 1)
    }

    func test_hoveringTheFoldedStack_leavesItFolded() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let front = try XCTUnwrap(toast(titled: "Third"))
        let over = front.convert(NSPoint(x: front.bounds.midX, y: front.bounds.midY), to: nil)

        let pile = presenter.pileForTesting
        NSApp.sendEvent(mouse(.mouseMoved, at: over))
        for view in [pile, front] { view.mouseEntered(with: mouse(.mouseMoved, at: over)) }

        XCTAssertFalse(pile.isUnfolded, "hover alone does not unfold")
    }

    func test_aClickOutside_foldsTheStackAndResumesTheCountdowns() throws {
        let presenter = presenter(dismissAfter: 0.1)
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        click(try XCTUnwrap(toast(titled: "Third")))
        XCTAssertTrue(pile.isUnfolded, "precondition")

        click(at: NSPoint(x: 20, y: 20))

        XCTAssertFalse(pile.isUnfolded, "a click elsewhere in the window folds the stack")
        XCTAssertTrue(visible("Third", in: pile))
        XCTAssertFalse(visible("Second", in: pile))
        waitUntil(
            descendants(of: pile).compactMap { $0 as? ToastView }.isEmpty, "the countdowns to run again once folded")
    }

    func test_showLess_foldsTheStack() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        click(try XCTUnwrap(toast(titled: "Third")))
        XCTAssertTrue(pile.isUnfolded, "precondition")

        click(pile.showLessForTesting)

        XCTAssertFalse(pile.isUnfolded)
    }

    func test_dismissingDownToOneToast_foldsTheStackAsItLeaves() throws {
        Motion.isReduceMotionEnabled = { false }
        let presenter = presenter()
        presenter.show(notice("First"))
        presenter.show(notice("Second"))
        let pile = presenter.pileForTesting
        click(try XCTUnwrap(toast(titled: "Second")))
        XCTAssertTrue(pile.isUnfolded, "precondition")

        click(try XCTUnwrap(toast(titled: "Second")))

        XCTAssertNotNil(toast(titled: "Second"), "precondition: still on its way out")
        XCTAssertFalse(pile.isUnfolded, "one toast left is not a stack")
        XCTAssertTrue(visible("First", in: pile), "and the next toast steps forward")
    }

    func test_dismissingDownToOneToastUnderReduceMotion_foldsTheStack() throws {
        let presenter = presenter()
        presenter.show(notice("First"))
        presenter.show(notice("Second"))
        let pile = presenter.pileForTesting
        click(try XCTUnwrap(toast(titled: "Second")))
        XCTAssertTrue(pile.isUnfolded, "precondition")

        click(try XCTUnwrap(toast(titled: "Second")))

        XCTAssertNil(toast(titled: "Second"), "precondition: gone at once without motion")
        XCTAssertFalse(pile.isUnfolded, "one toast left is not a stack")
        XCTAssertTrue(visible("First", in: pile))
    }

    func test_theFrontToastsActionAndClose_workWhileFolded() throws {
        let presenter = presenter()
        presenter.show(notice("First"))
        presenter.show(notice("Second"))
        var acted = false
        var closed = false
        let front = presenter.showSticky(
            notice("Third"), actions: [ToastAction(title: "Open", kind: .primary) { acted = true }],
            showsClose: true)
        front.onClose = { closed = true }
        window.contentView!.layoutSubtreeIfNeeded()
        let buttons = descendants(of: front)
        let action = try XCTUnwrap(buttons.compactMap { $0 as? AppButton }.first)
        let close = try XCTUnwrap(buttons.compactMap { $0 as? IconButton }.first)

        click(action)
        click(close)

        XCTAssertTrue(acted, "the action fires through the folded stack")
        XCTAssertTrue(closed, "and so does close")
        XCTAssertFalse(presenter.pileForTesting.isUnfolded, "neither unfolds the stack")
    }
}

private final class ClickCatcher: NSView {
    private(set) var clicked = false

    override func mouseDown(with event: NSEvent) { clicked = true }
}
