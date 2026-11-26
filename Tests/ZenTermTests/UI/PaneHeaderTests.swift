import AppKit
import XCTest

@testable import ZenTerm

final class PaneHeaderTests: WindowTestCase {
    private let shell = PaneHeader.Label(text: "~/Dev/zen-term", isPath: true)
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
        let header = PaneHeader(label: shell, controls: controls) { [weak self] in self?.chosen.append($0) }
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

    func test_theLabel_staysMuted_whereverFocusSits() {
        let (header, _) = mounted()
        XCTAssertEqual(header.labelInkForTesting, Theme.current.chrome.ink(.muted))

        header.isActive = true

        XCTAssertEqual(header.labelInkForTesting, Theme.current.chrome.ink(.muted), "a quiet place for context")
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

    func test_aControl_restsMuted_andLightsUnderThePointer() throws {
        let (header, _) = mounted()
        header.isActive = true
        let button = try XCTUnwrap(header.buttonForTesting(.close))
        XCTAssertEqual(button.iconTintForTesting, Theme.current.chrome.ink(.muted), "controls recede behind the label")

        try enter(button)

        XCTAssertEqual(button.iconTintForTesting, Theme.current.chrome.ink(.normal))
    }

    func test_aNarrowHeader_truncatesTheLabelFirst_thenDropsEveryControlButClose() {
        let all: [PaneHeader.Control] = [.splitHorizontal, .splitVertical, .focusMode, .close]
        XCTAssertEqual(mounted().0.visibleControlsForTesting, all)
        XCTAssertEqual(mounted(width: 220).0.visibleControlsForTesting, all, "a short label truncates; controls stay")
        XCTAssertEqual(mounted(width: 120).0.visibleControlsForTesting, [.close])
    }

    func test_aPathTruncatesFromItsFront_aTitleFromItsEnd() {
        let (header, _) = mounted()
        XCTAssertEqual(header.labelTruncationForTesting, .byTruncatingHead, "the folder you are in survives")

        header.label = PaneHeader.Label(text: "✳ A long task title")

        XCTAssertEqual(header.labelTruncationForTesting, .byTruncatingTail)
    }
}
