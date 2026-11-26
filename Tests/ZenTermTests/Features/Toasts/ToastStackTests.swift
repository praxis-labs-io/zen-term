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
        window.setFrameOrigin(Self.originAwayFromThePointer(for: window.frame.size))
        window.orderFront(nil)
    }

    // Hover rechecks read the real pointer, so the window must not sit under it.
    private static func originAwayFromThePointer(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first?.frame ?? .zero
        let pointer = NSEvent.mouseLocation
        let x = pointer.x < screen.midX ? screen.maxX - size.width : screen.minX
        let y = pointer.y < screen.midY ? screen.maxY - size.height : screen.minY
        return NSPoint(x: x, y: y)
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
        XCTAssertEqual(pile.plateOpacityForTesting, [1, 1], "two opaque cards sit behind the front one")
        XCTAssertEqual(
            pile.plateRecessionForTesting, ChromeTheme.toastRecession, "each fades toward the background by its step")
        XCTAssertTrue(
            pile.isStackedBackToFrontForTesting, "Show Less, then the deepest plate, sit behind everything nearer")
        XCTAssertEqual(
            pile.frame.height,
            front.frame.height + 2 * ChromeMetrics.Spacing.s12 + ChromeMetrics.Spacing.s8
                + pile.listToggleForTesting.frame.height,
            "the folded stack is one card tall plus the receding edges and room for Show More")
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

        click(pile.listToggleForTesting)

        XCTAssertFalse(pile.isUnfolded)
    }

    func test_aClickBesideTheStack_reachesWhatIsUnderIt() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let front = try XCTUnwrap(toast(titled: "Third"))
        let beside = front.convert(NSPoint(x: -4, y: front.bounds.midY), to: nil)
        let root = window.contentView!

        let hit = root.hitTest(root.convert(beside, from: nil))

        XCTAssertTrue(hit === root, "the padding around the stack never takes a click")
    }

    private func pointer(_ type: NSEvent.EventType, over view: NSView) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil)!
    }

    func test_aFoldedCardsPose_landsOnItsPlate() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        for (title, plate) in zip(["Second", "First"], pile.plateLayerFramesForTesting) {
            let view = try XCTUnwrap(toast(titled: title))
            let layer = try XCTUnwrap(view.layer)
            layer.transform = pile.restingPoseForTesting(view)
            let card = layer.frame
            layer.transform = CATransform3DIdentity
            XCTAssertEqual(card.minX, plate.minX, accuracy: 0.5, "\(title) narrows to its plate")
            XCTAssertEqual(card.maxX, plate.maxX, accuracy: 0.5)
            XCTAssertEqual(
                pile.isFlipped ? card.maxY : card.minY, pile.isFlipped ? plate.maxY : plate.minY, accuracy: 0.5,
                "\(title) sits on its plate's bottom edge")
        }
    }

    func test_unfolding_growsEachCardOutOfItsPlate() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        let second = try XCTUnwrap(toast(titled: "Second"))
        let folded = pile.restingPoseForTesting(second)
        Motion.isReduceMotionEnabled = { false }

        pile.unfold()

        let morph = try XCTUnwrap(second.layer?.animation(forKey: "motion.morph") as? CABasicAnimation)
        let from = try XCTUnwrap(morph.fromValue as? NSValue).caTransform3DValue
        let to = try XCTUnwrap(morph.toValue as? NSValue).caTransform3DValue
        XCTAssertTrue(CATransform3DEqualToTransform(from, folded), "it starts on its plate")
        XCTAssertTrue(CATransform3DIsIdentity(to), "and ends full size in the list")
    }

    func test_aToastArrivingOnAFullStack_pushesEachPlateBack() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        let plates = pile.plateLayersForTesting
        let ahead = [try XCTUnwrap(toast(titled: "Third")?.layer?.frame), plates[0].frame]
        Motion.isReduceMotionEnabled = { false }

        presenter.show(notice("Fourth"))

        for (plate, target) in zip(plates, ahead) {
            let morph = try XCTUnwrap(plate.animation(forKey: "motion.morph") as? CABasicAnimation)
            let from = try XCTUnwrap(morph.fromValue as? NSValue).caTransform3DValue
            plate.transform = from
            let start = plate.frame
            plate.transform = CATransform3DIdentity
            XCTAssertEqual(start.width, target.width, accuracy: 0.5, "each plate starts the size of the one ahead")
            XCTAssertEqual(start.midY, target.midY, accuracy: 0.5, "and where it sat")
        }
    }

    func test_aClickUnderTheFoldedStack_reachesTheTerminal_untilShowMoreShows() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        let toggle = pile.listToggleForTesting
        let under = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
        let root = window.contentView!

        XCTAssertTrue(root.hitTest(root.convert(under, from: nil)) === root, "a hidden footer takes no click")

        pile.mouseEntered(with: pointer(.mouseEntered, over: pile))
        XCTAssertTrue(root.hitTest(root.convert(under, from: nil)) === toggle, "Show More takes it once it shows")
    }

    func test_clear_showsOnlyWhenSomethingHandlesIt() {
        XCTAssertTrue(ToastPile().clearForTesting.isHidden, "a pile nobody clears shows no Clear")
        XCTAssertFalse(presenter().pileForTesting.clearForTesting.isHidden)
    }

    func test_clear_dismissesEveryToastInTheStack() throws {
        let presenter = presenter()
        showThree(on: presenter)
        let pile = presenter.pileForTesting
        click(try XCTUnwrap(toast(titled: "Third")))
        XCTAssertTrue(pile.isUnfolded, "precondition")

        click(pile.clearForTesting)

        waitUntil(pile.cards.isEmpty, "every toast to leave")
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

    func test_unfolding_resizesThePilesAncestorsInTheSamePass() {
        let pile = ToastPile(foldsOnClickOutside: false)
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let outer = NSView()
        outer.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(pile)
        outer.addSubview(row)
        let content = NSView()
        content.addSubview(outer)
        window.contentView = content
        NSLayoutConstraint.activate([
            pile.topAnchor.constraint(equalTo: row.topAnchor),
            pile.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            pile.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            pile.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            row.topAnchor.constraint(equalTo: outer.topAnchor),
            row.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        ])
        for title in ["First", "Second", "Third"] {
            pile.add(ToastView(content: notice(title), actions: [], showsClose: false))
        }
        content.layoutSubtreeIfNeeded()
        let folded = outer.frame.height

        pile.unfold()

        XCTAssertGreaterThan(pile.frame.height, folded, "the unfolded list is taller than the fold")
        XCTAssertEqual(
            outer.frame.height, pile.frame.height, "the pile's ancestors resize in the same pass as the pile")
    }
}

private final class ClickCatcher: NSView {
    private(set) var clicked = false

    override func mouseDown(with event: NSEvent) { clicked = true }
}
