import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class CloseConfirmCardTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func twoRunningPanes() throws -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        controller = c
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(paneCount(c), 2, "precondition: the split took")
        spawned.forEach { $0.isBusy = true }
        try pressChord("w", .command, keyCode: 13, in: c)
        return c
    }

    private func paneCount(_ c: WindowController) -> Int {
        c.activeTabIDForTesting.flatMap { c.controllerForTesting(tab: $0)?.allSurfaces.count } ?? 0
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func card(in c: WindowController) -> ConfirmCard? {
        c.window.contentView.flatMap { descendants(of: $0).compactMap { $0 as? ConfirmCard }.first }
    }

    private func button(_ title: String, in card: ConfirmCard) throws -> AppButton {
        try XCTUnwrap(descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == title })
    }

    // What the pointer lands on, so the backdrop or the card's own chrome cannot be taking the click.
    private func click(_ button: AppButton) throws {
        let content = try XCTUnwrap(button.window?.contentView)
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = content.hitTest(content.convert(center, from: nil))
        XCTAssertTrue(hit === button, "the click lands on \(button.title), not \(String(describing: hit))")
        (hit as? NSButton)?.performClick(nil)
    }

    func test_closingARunningPane_asksInACard_focusedOnClose_andRaisesNoToast() throws {
        let c = try twoRunningPanes()

        XCTAssertTrue(c.isConfirmOpen)
        let card = try XCTUnwrap(card(in: c), "the confirm is a card")
        XCTAssertTrue(confirmTexts(in: c).contains("Close Pane"), "\(confirmTexts(in: c))")
        XCTAssertTrue(
            confirmTexts(in: c).contains("Closing this pane will stop the process running in it."),
            "\(confirmTexts(in: c))")
        XCTAssertTrue(toastTexts(in: c).isEmpty, "no toast asks the question: \(toastTexts(in: c))")
        XCTAssertTrue(
            c.window.firstResponder === (try button("Close", in: card)),
            "a close is answered with Return as before, so the card starts on Close")
    }

    func test_return_closesThePane() throws {
        let c = try twoRunningPanes()

        try sendKeys([.returnKey], to: c)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertNil(card(in: c), "the card comes down")
        XCTAssertEqual(paneCount(c), 1, "Return on the focused Close closes the pane")
    }

    func test_escape_cancels_andHandsTheKeyboardBack() throws {
        let c = try twoRunningPanes()

        try sendKeys([.escape], to: c)

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertNil(card(in: c))
        XCTAssertEqual(paneCount(c), 2, "Esc closes nothing")
        XCTAssertFalse(c.window.firstResponder is AppButton, "the keyboard goes back to the terminal")
    }

    func test_clickingClose_closesThePane() throws {
        let c = try twoRunningPanes()
        let card = try XCTUnwrap(card(in: c))

        try click(try button("Close", in: card))

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertEqual(paneCount(c), 1)
    }

    func test_clickingCancel_closesNothing() throws {
        let c = try twoRunningPanes()
        let card = try XCTUnwrap(card(in: c))

        try click(try button("Cancel", in: card))

        XCTAssertFalse(c.isConfirmOpen)
        XCTAssertEqual(paneCount(c), 2)
    }
}
