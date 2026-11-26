import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SpinnerTests: WindowTestCase {
    private var windows: [NSWindow] = []

    private func mountedSpinner(role: KeyPath<ChromeTheme, TerminalColor> = \.accent) -> Spinner {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let spinner = Spinner()
        spinner.role = role
        window.contentView?.addSubview(spinner)
        spinner.frame = NSRect(x: 0, y: 0, width: 13, height: 13)
        spinner.layoutSubtreeIfNeeded()
        windows.append(window)
        return spinner
    }

    private func stepTicks(of spinner: Spinner) throws -> [Double] {
        let arc = spinner.arcForTesting
        let keys = try XCTUnwrap(arc.animationKeys(), "the arc steps")
        XCTAssertEqual(keys.count, 2, "it turns and it stretches")
        return keys.compactMap { arc.animation(forKey: $0)?.beginTime }.map { $0 / Spinner.frameInterval }
    }

    func test_spinnersStartedAtDifferentMoments_stepOnTheSameClockTicks() throws {
        Motion.isReduceMotionEnabled = { false }
        let first = mountedSpinner()
        let firstStarted = CACurrentMediaTime() / Spinner.frameInterval
        first.isSpinning = true
        RunLoop.current.run(until: Date().addingTimeInterval(Spinner.frameInterval * 1.5))
        let second = mountedSpinner()
        second.isSpinning = true

        for tick in try stepTicks(of: first) + stepTicks(of: second) {
            XCTAssertEqual(tick, tick.rounded(), accuracy: 0.001, "a step lands on a shared clock tick")
            XCTAssertGreaterThanOrEqual(tick + 0.001, firstStarted.rounded(.up), "the step starts on the next tick")
        }
    }

    func test_theLoop_alwaysShowsAnArc_andOnlyEverTurnsOneWay() {
        let frames = Spinner.frames
        XCTAssertTrue(frames.allSatisfy { $0.arcLength > 0 && $0.arcLength < 1 })
        var largestStep: CGFloat = 0
        for (index, frame) in frames.enumerated().dropFirst() {
            let step = frames[index - 1].rotation - frame.rotation
            XCTAssertGreaterThan(step, 0, "frame \(index) turns back")
            largestStep = max(largestStep, step)
        }
        var seam = (frames[frames.count - 1].rotation - frames[0].rotation).truncatingRemainder(dividingBy: 2 * .pi)
        if seam < 0 { seam += 2 * .pi }
        XCTAssertGreaterThan(seam, 0)
        XCTAssertLessThanOrEqual(seam, largestStep + 0.001, "the loop's seam jumps further than any other step")
    }

    func test_underReduceMotion_aSpinningSpinnerShowsItsRolesStillDot_andAnimatesNothing() {
        Motion.isReduceMotionEnabled = { true }
        let working = mountedSpinner(role: \.working)
        let loading = mountedSpinner()
        working.isSpinning = true
        loading.isSpinning = true

        XCTAssertEqual(working.stillDotStateForTesting, .working)
        XCTAssertEqual(loading.stillDotStateForTesting, .live)
        for spinner in [working, loading] {
            XCTAssertNil(spinner.arcForTesting.animationKeys())
            XCTAssertTrue(spinner.arcForTesting.isHidden)
        }
    }

    func test_withMotion_aSpinningSpinnerShowsTheRing_notTheDot() {
        Motion.isReduceMotionEnabled = { false }
        let spinner = mountedSpinner(role: \.working)
        spinner.isSpinning = true

        XCTAssertNil(spinner.stillDotStateForTesting)
        XCTAssertNil(spinner.subviews.compactMap { ($0 as? StateDot)?.state }.first, "a hidden dot reports no state")
        XCTAssertNotNil(spinner.arcForTesting.path, "the ring is drawn")
        XCTAssertFalse(spinner.arcForTesting.isHidden)
        XCTAssertNotNil(spinner.arcForTesting.animationKeys())
    }
}
