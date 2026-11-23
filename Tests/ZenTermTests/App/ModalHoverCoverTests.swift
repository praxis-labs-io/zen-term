import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

private final class ButtonOverlay: NSView, ModalOverlay {
    let button = IconButton(symbol: "xmark", accessibilityLabel: "Close") {}

    init() {
        super.init(frame: .zero)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() {}
    func animateIn() {}
    func animateOut(completion: @escaping () -> Void) { completion() }
}

@MainActor
final class ModalHoverCoverTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        controller = c
        return c
    }

    private func tabChip(in c: WindowController) throws -> TerminalTabChip {
        let content = try XCTUnwrap(c.window.contentView)
        return try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabChip }.first)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func crossing(_ type: NSEvent.EventType, over view: NSView) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
    }

    func test_aModal_takesTheHoverOffATabChipBehindIt() throws {
        let c = makeWindow()
        let chip = try tabChip(in: c)
        chip.mouseEntered(with: try crossing(.mouseEntered, over: chip))
        XCTAssertTrue(chip.isCloseVisibleForTesting, "premise: a hovered chip shows its close button")

        c.presentModalForTesting(ButtonOverlay())

        XCTAssertFalse(chip.isCloseVisibleForTesting, "the chip behind the modal must not read as hovered")
        XCTAssertNotEqual(chip.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)
    }

    func test_aTabChipEnteredUnderAModal_showsNoHover() throws {
        let c = makeWindow()
        let chip = try tabChip(in: c)
        c.presentModalForTesting(ButtonOverlay())

        chip.mouseEntered(with: try crossing(.mouseEntered, over: chip))

        XCTAssertFalse(chip.isCloseVisibleForTesting, "the pointer crossing a covered chip must not light it")
    }

    func test_theModalsOwnControls_keepTheirHover() throws {
        let c = makeWindow()
        let overlay = ButtonOverlay()
        c.presentModalForTesting(overlay)

        overlay.button.mouseEntered(with: try crossing(.mouseEntered, over: overlay.button))

        XCTAssertEqual(overlay.button.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)
    }

    func test_closingTheModal_givesHoverBackToWhatItCovered() throws {
        let c = makeWindow()
        let chip = try tabChip(in: c)
        c.presentModalForTesting(ButtonOverlay())
        c.closeModalForTesting()

        chip.mouseEntered(with: try crossing(.mouseEntered, over: chip))

        XCTAssertTrue(chip.isCloseVisibleForTesting)
    }

    func test_closingTheModal_leavesHoverDownWhereItsOwnerHeldIt() throws {
        let c = makeWindow()
        let chip = try tabChip(in: c)
        chip.setHoverSuppressed(true)
        c.presentModalForTesting(ButtonOverlay())
        c.closeModalForTesting()

        chip.mouseEntered(with: try crossing(.mouseEntered, over: chip))

        XCTAssertFalse(chip.isCloseVisibleForTesting, "the modal lifts only the hover it took")
    }
}
