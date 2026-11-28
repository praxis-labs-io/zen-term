import AppKit
import XCTest

@testable import ZenTerm

final class SegmentedControlTests: WindowTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { false }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func mount(selected: Int = 0, onChange: @escaping (Int) -> Void = { _ in }) -> SegmentedControl {
        let control = SegmentedControl(options: ["Off", "Auto", "On"], selectedIndex: selected, onChange: onChange)
        window.contentView?.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            control.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        return control
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func click(segment index: Int, of control: SegmentedControl) throws {
        let segment = control.segmentsForTesting[index]
        let point = segment.convert(NSPoint(x: segment.bounds.midX, y: segment.bounds.midY), to: nil)
        let target = try XCTUnwrap(window.contentView?.hitTest(point), "nothing takes the click")
        target.mouseDown(with: try mouse(.leftMouseDown, at: point))
        target.mouseUp(with: try mouse(.leftMouseUp, at: point))
    }

    private func arrow(_ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    func test_fillsWidth_givesEverySegmentAnEqualShare_spanningTheTrack() throws {
        let control = SegmentedControl(options: ["This Mac", "Mac and display"], fillsWidth: true) { _ in }
        window.contentView?.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            control.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            control.widthAnchor.constraint(equalToConstant: 300),
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        let segments = control.segmentsForTesting.map(\.frame)

        XCTAssertEqual(segments[0].width, segments[1].width, "the segments are not equal shares")
        XCTAssertEqual(segments[0].minX, ChromeMetrics.Spacing.s2)
        XCTAssertEqual(segments[1].minX, segments[0].maxX)
        XCTAssertEqual(segments[1].maxX, 300 - ChromeMetrics.Spacing.s2, "the segments do not reach the track's end")
        XCTAssertFalse(control.hasAmbiguousLayout || control.segmentsForTesting.contains(where: \.hasAmbiguousLayout))

        try click(segment: 1, of: control)
        control.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            control.selectedSurfaceFrameForTesting, segments[1], "the selected surface does not cover its segment")
    }

    func test_clickingASegment_selectsIt_andSlidesTheRaisedSurfaceOntoIt() throws {
        var changes: [Int] = []
        let control = mount { changes.append($0) }

        try click(segment: 2, of: control)

        XCTAssertEqual(control.selectedIndex, 2)
        XCTAssertEqual(changes, [2])
        XCTAssertEqual(control.selectedSurfaceFrameForTesting, control.segmentsForTesting[2].frame)
        XCTAssertTrue(control.isSelectedSurfaceSlidingForTesting, "the selection jumps instead of sliding")
    }

    func test_arrowKeys_moveTheSelection() throws {
        var changes: [Int] = []
        let control = mount { changes.append($0) }
        XCTAssertTrue(window.makeFirstResponder(control))

        window.sendEvent(try arrow(124))
        window.sendEvent(try arrow(124))
        window.sendEvent(try arrow(123))

        XCTAssertEqual(changes, [1, 2, 1])
        XCTAssertEqual(control.selectedSurfaceFrameForTesting, control.segmentsForTesting[1].frame)
    }

    func test_theSelectedSegment_takesTheActiveFillInsideTheTrack() {
        let control = mount(selected: 1)
        let chrome = Theme.current.chrome

        XCTAssertEqual(control.layer?.backgroundColor, chrome.fill(.rest).cgColor)
        XCTAssertEqual(control.selectedSurfaceFillForTesting, chrome.fill(.active).cgColor)
        XCTAssertEqual(control.selectedSurfaceFrameForTesting, control.segmentsForTesting[1].frame)
        XCTAssertEqual(control.selectedSurfaceFrameForTesting.height, ChromeMetrics.Height.sm)
        XCTAssertEqual(control.frame.height, ChromeMetrics.Height.control)
        XCTAssertEqual(control.segmentInkForTesting(1), chrome.ink(.normal))
        XCTAssertEqual(control.segmentInkForTesting(0), chrome.ink(.subtle))
    }

    func test_hoveringAnUnselectedSegment_fillsIt_andHoveringTheSelectedOneDoesNot() throws {
        let control = mount(selected: 0)
        let chrome = Theme.current.chrome

        control.segmentsForTesting[2].mouseEntered(with: try crossing(.mouseEntered))
        control.segmentsForTesting[0].mouseEntered(with: try crossing(.mouseEntered))

        XCTAssertEqual(control.segmentFillForTesting(2), chrome.fill(.hover).cgColor)
        XCTAssertEqual(control.segmentInkForTesting(2), chrome.ink(.normal))
        XCTAssertEqual(control.segmentFillForTesting(0), NSColor.clear.cgColor)
    }

    func test_focus_ringsTheTrack() {
        let control = mount()

        XCTAssertTrue(window.makeFirstResponder(control))

        XCTAssertEqual(control.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
        XCTAssertEqual(control.layer?.borderWidth, ChromeMetrics.Border.width)
    }

    func test_aDisabledControl_ignoresClicks_showsNoRing_andFadesItsLabels() throws {
        var changes: [Int] = []
        let control = mount { changes.append($0) }
        control.isEnabled = false

        try click(segment: 2, of: control)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(control.selectedIndex, 0)
        XCTAssertFalse(control.acceptsFirstResponder, "the key loop would stop on a disabled control")
        window.makeFirstResponder(control)
        XCTAssertEqual(control.layer?.borderColor?.alpha, 0, "a disabled control shows no ring")
        XCTAssertEqual(control.segmentInkForTesting(0), Theme.current.chrome.ink(.faint))
        XCTAssertEqual(control.segmentInkForTesting(2), Theme.current.chrome.ink(.faint))
    }

    func test_aPressThatEndsAfterTheControlIsDisabled_selectsNothing() throws {
        var changes: [Int] = []
        let control = mount { changes.append($0) }
        let segment = control.segmentsForTesting[2]
        let point = segment.convert(NSPoint(x: segment.bounds.midX, y: segment.bounds.midY), to: nil)
        let target = try XCTUnwrap(window.contentView?.hitTest(point))

        target.mouseDown(with: try mouse(.leftMouseDown, at: point))
        control.isEnabled = false
        target.mouseUp(with: try mouse(.leftMouseUp, at: point))

        XCTAssertEqual(changes, [])
        XCTAssertEqual(control.selectedIndex, 0)
    }

    func test_eachSegmentIsARadioButtonVoiceOverCanPress() {
        var changes: [Int] = []
        let control = mount { changes.append($0) }
        let segment = control.segmentsForTesting[1]

        XCTAssertEqual(control.accessibilityRole(), .radioGroup)
        XCTAssertEqual(segment.accessibilityRole(), .radioButton)
        XCTAssertEqual(segment.accessibilityLabel(), "Auto")
        XCTAssertTrue(segment.accessibilityPerformPress())

        XCTAssertEqual(changes, [1])
        XCTAssertEqual(segment.accessibilityValue() as? Bool, true)
    }
}
