import AppKit
import XCTest

@testable import ZenTerm

final class PaneHeaderTests: WindowTestCase {
    private let shell = PaneHeader.Content(process: .shell, name: "zsh", detail: "~/Dev/zen-term")
    private var chosen: [PaneHeader.Control] = []

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
        chosen = []
    }

    private func mounted(
        width: CGFloat = 480, controls: [PaneHeader.Control] = [.splitHorizontal, .splitVertical, .focusMode, .close]
    ) -> (PaneHeader, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width + 40, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let header = PaneHeader(content: shell, controls: controls) { [weak self] in self?.chosen.append($0) }
        window.contentView?.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            header.widthAnchor.constraint(equalToConstant: width),
            header.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        header.updateConstraintsForSubtreeIfNeeded()
        return (header, window)
    }

    private func click(_ button: IconButton, in window: NSWindow) throws {
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { button.mouseDown(with: event) } else { button.mouseUp(with: event) }
        }
    }

    private func enter(_ view: NSView) throws {
        let event = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: event)
    }

    func test_whereFocusSits_theNameTakesTheNormalInk_elsewhereTheSubtle() {
        let (header, _) = mounted()
        let chrome = Theme.current.chrome
        XCTAssertEqual(header.nameInkForTesting, chrome.ink(.subtle))

        header.isActive = true

        XCTAssertEqual(header.nameInkForTesting, chrome.ink(.normal))
    }

    func test_anUnfocusedHeader_showsItsControlsOnlyUnderThePointer() throws {
        let (header, _) = mounted()
        XCTAssertFalse(header.controlsShownForTesting)

        try enter(header)

        XCTAssertTrue(header.controlsShownForTesting, "the pointer over the header fades the controls in")
    }

    func test_aControl_reportsItselfOnRelease() throws {
        let (header, window) = mounted()
        header.isActive = true

        try click(try XCTUnwrap(header.buttonForTesting(.splitVertical)), in: window)

        XCTAssertEqual(chosen, [.splitVertical])
    }

    func test_aNarrowHeader_dropsEveryControlButClose() {
        XCTAssertEqual(
            mounted().0.visibleControlsForTesting, [.splitHorizontal, .splitVertical, .focusMode, .close])
        XCTAssertEqual(mounted(width: 120).0.visibleControlsForTesting, [.close])
    }

    func test_aModesReport_takesTheDetailsPlace_andGivesItBack() {
        let (header, _) = mounted()

        header.modeDetail = "Scroll: at bottom"
        XCTAssertEqual(header.detailForTesting, "Scroll: at bottom")

        header.modeDetail = nil
        XCTAssertEqual(header.detailForTesting, "~/Dev/zen-term")
    }

    func test_theDetail_truncatesRatherThanWraps() throws {
        let (header, _) = mounted()
        XCTAssertEqual(try XCTUnwrap(header.detailParagraphStyleForTesting).lineBreakMode, .byTruncatingTail)
    }
}
