import XCTest

@testable import ZenTerm

final class KeepAwakeSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    private func timed(left seconds: TimeInterval) -> KeepAwake.Hold {
        KeepAwake.Hold(until: .duration(60 * 60), endsAt: now.addingTimeInterval(seconds), graceEndsAt: nil)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        now.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }

    private let untilOff = KeepAwake.Hold(until: .turnedOff, endsAt: nil, graceEndsAt: nil)
    private let untilAgents = KeepAwake.Hold(until: .agentsFinish, endsAt: nil, graceEndsAt: nil)

    func test_footerDetail_namesWhatEndsTheHold() {
        XCTAssertNil(KeepAwakeSummary.footerDetail(hold: untilOff, activeCount: 3, now: now))
        XCTAssertEqual(KeepAwakeSummary.footerDetail(hold: untilAgents, activeCount: 3, now: now), "3 agents")
        XCTAssertEqual(KeepAwakeSummary.footerDetail(hold: untilAgents, activeCount: 1, now: now), "1 agent")
        let grace = KeepAwake.Hold(until: .agentsFinish, endsAt: nil, graceEndsAt: now.addingTimeInterval(44.2))
        XCTAssertEqual(KeepAwakeSummary.footerDetail(hold: grace, activeCount: 0, now: now), "ending in 45s")
    }

    func test_footerDetail_countsMinutes_thenSeconds_roundingUp() {
        let cases: [(TimeInterval, String)] = [
            (2 * 60 * 60, "2h"), (60 * 60 + 30 * 60, "1h 30m"), (42 * 60, "42m"), (41 * 60 + 1, "42m"),
            (61, "2m"), (60, "60s"), (44.5, "45s"),
        ]
        for (left, detail) in cases {
            XCTAssertEqual(
                KeepAwakeSummary.footerDetail(hold: timed(left: left), activeCount: 0, now: now), detail,
                "\(left)s left")
        }
    }

    func test_sentence_saysWhatIsHeld_andWhatEndsIt() {
        XCTAssertEqual(
            KeepAwakeSummary.sentence(hold: untilAgents, keepsDisplayOn: false, activeCount: 3, now: now),
            "Awake until 3 working agents finish. The display can still sleep.")
        XCTAssertEqual(
            KeepAwakeSummary.sentence(hold: untilAgents, keepsDisplayOn: false, activeCount: 1, now: now),
            "Awake until 1 working agent finishes. The display can still sleep.")
        XCTAssertEqual(
            KeepAwakeSummary.sentence(hold: untilOff, keepsDisplayOn: true, activeCount: 0, now: now),
            "Awake and display on until you turn it off.")
        XCTAssertEqual(
            KeepAwakeSummary.sentence(hold: timed(left: 42 * 60), keepsDisplayOn: true, activeCount: 0, now: now),
            "Awake and display on for 42 more minutes, until \(clock(42 * 60)).")
        XCTAssertEqual(
            KeepAwakeSummary.sentence(hold: timed(left: 90 * 60), keepsDisplayOn: false, activeCount: 0, now: now),
            "Awake for 1 hour and 30 more minutes, until \(clock(90 * 60)). The display can still sleep.")
        XCTAssertEqual(
            KeepAwakeSummary.sentence(hold: timed(left: 120 * 60), keepsDisplayOn: true, activeCount: 0, now: now),
            "Awake and display on for 2 more hours, until \(clock(120 * 60)).")
        let grace = KeepAwake.Hold(until: .agentsFinish, endsAt: nil, graceEndsAt: now.addingTimeInterval(1))
        XCTAssertEqual(
            KeepAwakeSummary.sentence(hold: grace, keepsDisplayOn: true, activeCount: 0, now: now),
            "Agents finished. Awake and display on for 1 more second.")
    }

    func test_batteryIsLow_fromTenPointsAboveTheStop_onBatteryOnly() {
        let at = { BatteryReading(isOnBattery: true, percent: $0) }
        XCTAssertTrue(KeepAwakeSummary.isBatteryLow(at(20), stop: 10))
        XCTAssertFalse(KeepAwakeSummary.isBatteryLow(at(21), stop: 10))
        XCTAssertFalse(KeepAwakeSummary.isBatteryLow(BatteryReading(isOnBattery: false, percent: 5), stop: 10))
        XCTAssertFalse(KeepAwakeSummary.isBatteryLow(at(5), stop: nil), "a Never stop never warns")
        XCTAssertFalse(KeepAwakeSummary.isBatteryLow(nil, stop: 10), "a Mac with no battery never warns")
    }

    func test_nextChange_waitsForTheShownTextToChange() {
        XCTAssertNil(KeepAwakeSummary.nextChange(hold: untilAgents, now: now))
        XCTAssertEqual(
            try XCTUnwrap(KeepAwakeSummary.nextChange(hold: timed(left: 42 * 60 + 10), now: now)), 10, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(KeepAwakeSummary.nextChange(hold: timed(left: 42 * 60), now: now)), 60, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(KeepAwakeSummary.nextChange(hold: timed(left: 44.25), now: now)), 0.25, accuracy: 0.001)
        let grace = KeepAwake.Hold(until: .agentsFinish, endsAt: nil, graceEndsAt: now.addingTimeInterval(30))
        XCTAssertEqual(try XCTUnwrap(KeepAwakeSummary.nextChange(hold: grace, now: now)), 1, accuracy: 0.001)
    }
}
