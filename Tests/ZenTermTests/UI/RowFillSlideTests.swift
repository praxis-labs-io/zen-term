import AppKit
import XCTest

@testable import ZenTerm

final class RowFillSlideTests: WindowTestCase {
    private var window: NSWindow!
    private var host: FlippedView!
    private var rows: [NavRow] = []
    private var slide: RowFillSlide!

    private func assertShowsItsFill(_ row: NavRow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(row.layer?.backgroundColor, row.restingFill.cgColor, file: file, line: line)
        XCTAssertGreaterThan(row.layer?.backgroundColor?.alpha ?? 0, 0, "the row is lit", file: file, line: line)
    }
    private var clear: CGColor { NSColor.clear.cgColor }

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { false }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        host = FlippedView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView?.addSubview(host)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: ChromeMetrics.Spacing.s12),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        slide = RowFillSlide(host: host)
        rows = ["one", "two", "three"].map { NavRow(title: $0) {} }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            slide.adopt(row)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        host.layoutSubtreeIfNeeded()
    }

    override func tearDownWithError() throws {
        window = nil
        host = nil
        rows = []
        slide = nil
        try super.tearDownWithError()
    }

    func test_movingTheCurrentRow_slidesTheFillToIt_andHoldsTheRowsOwnFill() throws {
        rows[0].isCurrent = true
        XCTAssertFalse(slide.isSlidingForTesting(.current), "a fill with no row before it appears in place")
        assertShowsItsFill(rows[0])

        rows[2].isCurrent = true
        rows[0].isCurrent = false

        XCTAssertTrue(slide.isSlidingForTesting(.current))
        XCTAssertTrue(slide.slidingRowForTesting(.current) === rows[2])
        XCTAssertEqual(slide.slideFrameForTesting(.current), slide.frameForTesting(of: rows[2]))
        let rowLayer = try XCTUnwrap(rows[2].layer)
        XCTAssertEqual(
            try XCTUnwrap(host.layer).convert(slide.slideFrameForTesting(.current), to: rowLayer), rowLayer.bounds,
            "the slide covers the row it lands on")
        XCTAssertEqual(rows[2].layer?.backgroundColor, clear, "the slide stands in for the row's fill")
        XCTAssertEqual(rows[0].layer?.backgroundColor, clear, "the row the fill left lets go at once")
    }

    func test_whenTheSlideLands_theRowShowsItsFill() {
        rows[0].isCurrent = true
        rows[0].isCurrent = false
        rows[1].isCurrent = true
        XCTAssertTrue(slide.isSlidingForTesting(.current), "precondition")
        let carried = slide.slideColorForTesting(.current)

        waitUntil(slide.slidingRowForTesting(.current) == nil, "the slide to land")
        XCTAssertEqual(rows[1].layer?.backgroundColor, carried, "the slide lands in the fill the row then shows")

        XCTAssertFalse(slide.isSlidingForTesting(.current))
        assertShowsItsFill(rows[1])
    }

    func test_movingKeyboardFocus_slidesTheFocusFill() {
        window.makeFirstResponder(rows[0])
        assertShowsItsFill(rows[0])

        window.makeFirstResponder(rows[1])

        XCTAssertTrue(slide.isSlidingForTesting(.focus))
        XCTAssertTrue(slide.slidingRowForTesting(.focus) === rows[1])
        XCTAssertEqual(rows[1].layer?.backgroundColor, clear)
        XCTAssertFalse(slide.isSlidingForTesting(.current), "focus moving leaves the current fill alone")
    }

    func test_focusLeavingTheList_clearsInPlace() {
        window.makeFirstResponder(rows[0])

        window.makeFirstResponder(nil)

        XCTAssertFalse(slide.isSlidingForTesting(.focus))
        XCTAssertEqual(rows[0].layer?.backgroundColor?.alpha, 0)
    }

    func test_aRerenderThatKeepsTheCurrentRow_keepsTheSlide() {
        rows[0].isCurrent = true
        rows[0].isCurrent = false
        rows[1].isCurrent = true

        for (index, row) in rows.enumerated() { row.isCurrent = index == 1 }
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(slide.isSlidingForTesting(.current))
        XCTAssertTrue(slide.slidingRowForTesting(.current) === rows[1])
    }

    func test_aSecondMoveMidSlide_retargetsToTheNewRow() {
        rows[0].isCurrent = true
        rows[0].isCurrent = false
        rows[1].isCurrent = true
        rows[1].isCurrent = false
        rows[2].isCurrent = true

        XCTAssertTrue(slide.slidingRowForTesting(.current) === rows[2])
        XCTAssertEqual(slide.slideFrameForTesting(.current), slide.frameForTesting(of: rows[2]))
        XCTAssertEqual(rows[1].layer?.backgroundColor, clear, "the row passed over shows nothing")
    }

    func test_reduceMotion_snapsTheFillOntoTheRow() {
        Motion.isReduceMotionEnabled = { true }
        rows[0].isCurrent = true

        rows[0].isCurrent = false
        rows[1].isCurrent = true

        XCTAssertFalse(slide.isSlidingForTesting(.current))
        XCTAssertNil(slide.slidingRowForTesting(.current))
        assertShowsItsFill(rows[1])
        XCTAssertEqual(rows[0].layer?.backgroundColor, clear)
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func fillEase(on row: NavRow) -> CABasicAnimation? {
        row.layer?.animation(forKey: "motion.backgroundColor") as? CABasicAnimation
    }

    func test_clickingAHoveredRowCurrent_letsItsHoverKeepEasing() throws {
        rows[0].isCurrent = true
        rows[1].mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertNotNil(fillEase(on: rows[1]), "precondition: the hover eases in")

        rows[0].isCurrent = false
        rows[1].isCurrent = true

        XCTAssertTrue(slide.isSlidingForTesting(.current), "precondition")
        XCTAssertNotNil(fillEase(on: rows[1]), "the slide cut the hover's ease short")
    }

    func test_aSlideLandingOnARowHoveredMidSlide_fadesFromTheSlidesFill() throws {
        rows[0].isCurrent = true
        rows[0].isCurrent = false
        rows[1].isCurrent = true
        let carried = try XCTUnwrap(slide.slideColorForTesting(.current))
        rows[1].mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertNotEqual(rows[1].restingFill.cgColor, carried, "precondition: hover and current differ")

        waitUntil(slide.slidingRowForTesting(.current) == nil, "the slide to land")

        let fade = try XCTUnwrap(fillEase(on: rows[1]), "the landing switched to the hover fill")
        let from = try XCTUnwrap(fade.fromValue) as AnyObject
        XCTAssertTrue(CFEqual(from, carried), "the fade starts from the slide's fill")
        XCTAssertEqual(rows[1].layer?.backgroundColor, rows[1].restingFill.cgColor)
    }

    func test_thePointerLeavingTheCurrentRow_easesBackToItsFill() throws {
        Motion.isReduceMotionEnabled = { true }
        rows[1].isCurrent = true
        rows[1].mouseEntered(with: try crossing(.mouseEntered))
        Motion.isReduceMotionEnabled = { false }

        rows[1].mouseExited(with: try crossing(.mouseExited))

        XCTAssertNotNil(fillEase(on: rows[1]), "leaving the row switched its fill")
        XCTAssertEqual(rows[1].layer?.backgroundColor, rows[1].restingFill.cgColor)
    }

    func test_hoverStillFillsInPlace() throws {
        let row = rows[1]
        row.mouseEntered(
            with: try XCTUnwrap(
                NSEvent.enterExitEvent(
                    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                    userData: nil)))

        assertShowsItsFill(row)
        XCTAssertFalse(slide.isSlidingForTesting(.current))
        XCTAssertFalse(slide.isSlidingForTesting(.focus))
    }
}
