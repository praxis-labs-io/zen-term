import XCTest

@testable import ZenTerm

final class AgentStateTrackerTests: XCTestCase {
    private let id = SurfaceIDs.mint()
    private var clock = Date(timeIntervalSince1970: 1_000)

    private func makeTracker() -> AgentStateTracker {
        AgentStateTracker(now: { self.clock })
    }

    private func working(_ rule: String = "codex_title_working") -> AgentStateEngine.Outcome {
        .matched(.working, ruleID: rule)
    }

    func test_anUnchangedState_publishesNothing_howeverManyEventsArrive() {
        let tracker = makeTracker()
        XCTAssertEqual(tracker.publish(id, working()), .working)

        // Codex pushes ~10 of these a second, and none of them is a transition.
        for _ in 0..<50 {
            XCTAssertNil(tracker.publish(id, working()))
        }
    }

    func test_aDroppedSpinnerFrame_isHeld_ratherThanEndingTheTurn() {
        let tracker = makeTracker()
        _ = tracker.publish(id, working())

        XCTAssertNil(tracker.publish(id, .fallback), "one unmatched frame is not a finished turn")
        XCTAssertTrue(tracker.isHoldingIdle(id))

        clock += 0.1
        XCTAssertNil(tracker.publish(id, working()), "the spinner came back, so nothing changed")
        XCTAssertFalse(tracker.isHoldingIdle(id))
    }

    func test_aRealTurnEnd_landsOnceTheHoldElapses() {
        let tracker = makeTracker()
        _ = tracker.publish(id, working())
        XCTAssertNil(tracker.publish(id, .fallback))

        clock += AgentStateTracker.idleHold
        XCTAssertEqual(tracker.publish(id, .fallback), .idle)
        XCTAssertFalse(tracker.isHoldingIdle(id))
    }

    func test_aRuleThatSaysIdle_needsNoHold() {
        let tracker = makeTracker()
        _ = tracker.publish(id, working())

        XCTAssertEqual(
            tracker.publish(id, .matched(.idle, ruleID: "claude_progress_idle")), .idle,
            "positive evidence of idle is not a flicker")
    }

    func test_blocked_isNeverHeld() {
        let tracker = makeTracker()
        _ = tracker.publish(id, working())

        XCTAssertEqual(tracker.publish(id, .matched(.blocked, ruleID: "codex_title_blocked")), .blocked)
    }

    func test_aSkip_holdsWhateverWasPublished() {
        let tracker = makeTracker()
        _ = tracker.publish(id, working())

        XCTAssertNil(tracker.publish(id, .skip(ruleID: "viewer")))
        XCTAssertEqual(tracker.state(of: id), .working)
    }

    func test_aDroppedSurface_startsOver() {
        let tracker = makeTracker()
        _ = tracker.publish(id, working())

        tracker.drop(id)

        XCTAssertEqual(tracker.state(of: id), .idle)
        XCTAssertEqual(tracker.publish(id, working()), .working)
    }
}
