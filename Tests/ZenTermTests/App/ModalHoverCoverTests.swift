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

private final class IconPickerOverlay: NSView, ModalOverlay {
    let picker = IconPickerField(selected: IconCatalog.defaultSymbol)

    init() {
        super.init(frame: .zero)
        picker.frame = NSRect(x: 40, y: 200, width: 200, height: ChromeMetrics.Height.control)
        addSubview(picker)
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

    func test_aTabChipBuiltWhileAModalIsOpen_showsNoHover() throws {
        let c = makeWindow()
        c.presentModalForTesting(ButtonOverlay())
        c.newTabForTesting()
        c.window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(c.window.contentView)
        let chip = try XCTUnwrap(descendants(of: content).compactMap { $0 as? TerminalTabChip }.last)

        chip.mouseEntered(with: try crossing(.mouseEntered, over: chip))

        XCTAssertFalse(chip.isCloseVisibleForTesting, "a chip that arrives under the modal is covered too")
    }

    func test_anAppButtonBehindAModal_showsNoHover() throws {
        let c = makeWindow()
        let button = AppButton(title: "Retry", variant: .secondary)
        button.frame = NSRect(x: 40, y: 40, width: 80, height: ChromeMetrics.Height.control)
        c.window.contentView?.addSubview(button, positioned: .below, relativeTo: nil)
        c.presentModalForTesting(ButtonOverlay())

        button.mouseEntered(with: try crossing(.mouseEntered, over: button))

        XCTAssertNotEqual(button.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)
    }

    func test_anOwnerLiftingItsSuppressionUnderAModal_staysCovered() throws {
        let c = makeWindow()
        let chip = try tabChip(in: c)
        chip.setHoverSuppressed(true)
        c.presentModalForTesting(ButtonOverlay())

        chip.setHoverSuppressed(false)
        chip.mouseEntered(with: try crossing(.mouseEntered, over: chip))

        XCTAssertFalse(chip.isCloseVisibleForTesting, "the owner's flag and the modal's cover are separate")
    }

    func test_aPopoverOpenedInsideAModal_keepsItsHover() throws {
        let c = makeWindow()
        let overlay = IconPickerOverlay()
        c.presentModalForTesting(overlay)
        c.window.contentView?.layoutSubtreeIfNeeded()
        overlay.picker.openForTesting()
        let card = try XCTUnwrap(c.window.contentView?.subviews.last)
        let cells = descendants(of: card).compactMap { $0 as? IconButton }
        let cell = try XCTUnwrap(cells.last { $0 !== overlay.picker.highlightedCellForTesting })

        cell.mouseEntered(with: try crossing(.mouseEntered, over: cell))

        XCTAssertEqual(cell.layer?.backgroundColor, Theme.current.chrome.fill(.hover).cgColor)
    }
}
