import AppKit
import XCTest

@testable import ZenTerm

final class PaneHeaderTests: WindowTestCase {
    private let shell = PaneHeader.Content(process: .shell, name: "zsh", path: "~/Dev/zen-term")
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

    func test_nameAndPath_stayMuted_whereverFocusSits() {
        let (header, _) = mounted()
        let muted = Theme.current.chrome.ink(.muted)
        XCTAssertEqual(header.inksForTesting.name, muted)
        XCTAssertEqual(header.inksForTesting.path, muted)

        header.isActive = true

        XCTAssertEqual(header.inksForTesting.name, muted, "a quiet place for context")
        XCTAssertEqual(header.inksForTesting.path, muted)
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

    func test_aControlsTooltip_namesItsCommandAndShortcut() throws {
        let (header, _) = mounted()
        let split = try XCTUnwrap(header.buttonForTesting(.splitVertical))
        XCTAssertEqual(split.tooltipLabelForTesting, CommandCatalog.spec(for: .splitVertical).title)
        XCTAssertEqual(split.tooltipShortcutForTesting, CommandCatalog.spec(for: .splitVertical).shortcut)
    }

    func test_aFloatsClose_endsItsProgram_soItOffersNoHideShortcut() throws {
        let (header, _) = mounted(controls: [.minimize, .end])
        let minimize = try XCTUnwrap(header.buttonForTesting(.minimize))
        let end = try XCTUnwrap(header.buttonForTesting(.end))
        XCTAssertEqual(
            minimize.tooltipShortcutForTesting, CommandCatalog.spec(for: .closePane).shortcut, "⌘W hides a float")
        XCTAssertNil(end.tooltipShortcutForTesting, "nothing on the keyboard ends a float's program")
        XCTAssertEqual(end.tooltipLabelForTesting, "Close")
    }

    func test_aNarrowHeader_truncatesTheLabelFirst_thenDropsEveryControlButClose() {
        let all: [PaneHeader.Control] = [.splitHorizontal, .splitVertical, .focusMode, .close]
        XCTAssertEqual(mounted().0.visibleControlsForTesting, all)
        XCTAssertEqual(mounted(width: 220).0.visibleControlsForTesting, all, "a short label truncates; controls stay")
        XCTAssertEqual(mounted(width: 120).0.visibleControlsForTesting, [.close])
    }

    func test_thePathTruncatesFromItsFront_soItsFolderSurvives() {
        let (header, _) = mounted()
        XCTAssertEqual(header.pathTruncationForTesting, .byTruncatingHead)
    }

    func test_aToolFloatsHeader_hasNoPath() {
        let (header, _) = mounted(controls: [.minimize, .end])
        header.content = PaneHeader.Content(process: .tool, name: "Zen Octo", path: nil)
        XCTAssertEqual(header.nameForTesting, "Zen Octo")
        XCTAssertNil(header.pathForTesting)
    }
}
