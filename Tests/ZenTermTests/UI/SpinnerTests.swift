import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SpinnerTests: WindowTestCase {
    private var windows: [NSWindow] = []
    private var spinners: [Spinner] = []

    override func tearDown() {
        spinners.forEach { $0.isSpinning = false }
        super.tearDown()
    }

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
        spinners.append(spinner)
        return spinner
    }

    private func litDot(of spinner: Spinner) -> Int? {
        spinner.dotsForTesting.firstIndex { $0.opacity == 1 }
    }

    func test_spinnersStartedAtDifferentMoments_lightTheSameDot() {
        Motion.isReduceMotionEnabled = { false }
        let first = mountedSpinner()
        first.isSpinning = true
        Spinner.tickForTesting()
        let second = mountedSpinner()
        second.isSpinning = true

        XCTAssertNotNil(litDot(of: first))
        XCTAssertEqual(litDot(of: first), litDot(of: second))
        Spinner.tickForTesting()
        XCTAssertEqual(litDot(of: first), litDot(of: second))
    }

    func test_aTick_movesASpinningSpinnersLitDotOneForward_andLeavesAStoppedOneStill() throws {
        Motion.isReduceMotionEnabled = { false }
        let spinning = mountedSpinner()
        let stopped = mountedSpinner()
        spinning.isSpinning = true
        stopped.isSpinning = true
        stopped.isSpinning = false
        let before = try XCTUnwrap(litDot(of: spinning))
        let stoppedBefore = stopped.dotsForTesting.map(\.opacity)

        Spinner.tickForTesting()

        XCTAssertEqual(litDot(of: spinning), (before + 1) % spinning.dotsForTesting.count)
        XCTAssertEqual(stopped.dotsForTesting.map(\.opacity), stoppedBefore)
    }

    func test_aSpinner_isOnTheClockOnlyWhileItSpinsInAWindow() {
        Motion.isReduceMotionEnabled = { false }
        let loose = Spinner()
        loose.isSpinning = true
        XCTAssertFalse(loose.isOnClockForTesting)

        let mounted = mountedSpinner()
        mounted.isSpinning = true
        XCTAssertTrue(mounted.isOnClockForTesting)
        mounted.isSpinning = false
        XCTAssertFalse(mounted.isOnClockForTesting)
    }

    func test_underReduceMotion_aSpinningSpinnerShowsItsRolesStillDot_andStaysOffTheClock() {
        Motion.isReduceMotionEnabled = { true }
        let working = mountedSpinner(role: \.working)
        let loading = mountedSpinner()
        working.isSpinning = true
        loading.isSpinning = true

        XCTAssertEqual(working.stillDotStateForTesting, .working)
        XCTAssertEqual(loading.stillDotStateForTesting, .live)
        for spinner in [working, loading] {
            XCTAssertFalse(spinner.isOnClockForTesting)
            XCTAssertTrue(spinner.dotsForTesting.allSatisfy(\.isHidden))
        }
    }

    func test_withMotion_aSpinningSpinnerShowsTheDots_notTheStillDot() {
        Motion.isReduceMotionEnabled = { false }
        let spinner = mountedSpinner(role: \.working)
        spinner.isSpinning = true

        XCTAssertNil(spinner.stillDotStateForTesting)
        XCTAssertNil(spinner.subviews.compactMap { ($0 as? StateDot)?.state }.first, "a hidden dot reports no state")
        XCTAssertTrue(spinner.dotsForTesting.allSatisfy { !$0.isHidden && $0.backgroundColor != nil })
        XCTAssertTrue(spinner.isOnClockForTesting)
    }
}
