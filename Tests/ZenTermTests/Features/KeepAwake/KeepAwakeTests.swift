import XCTest

@testable import ZenTerm

final class KeepAwakeTests: XCTestCase {
    private var power: FakePowerAssertions!
    private var battery: FakeBatterySource!
    private var clock: FakeKeepAwakeClock!
    private var settings = KeepAwake.Settings(keepsDisplayOn: false, batteryStop: 10, grace: 60)
    private var working = 0
    private var releases: [KeepAwake.Release] = []
    private var keepAwake: KeepAwake!

    override func setUp() {
        super.setUp()
        power = FakePowerAssertions()
        battery = FakeBatterySource()
        clock = FakeKeepAwakeClock()
        settings = KeepAwake.Settings(keepsDisplayOn: false, batteryStop: 10, grace: 60)
        working = 0
        releases = []
        makeKeepAwake()
    }

    private func makeKeepAwake() {
        keepAwake = KeepAwake(
            power: power, battery: battery, clock: clock, settings: { [unowned self] in self.settings },
            activeCount: { [unowned self] in self.working })
        keepAwake.onRelease = { [unowned self] in self.releases.append($0) }
    }

    func test_keepAwake_holdsTheMacOnly_untilTurnedOff_withNoRelease() {
        XCTAssertNil(keepAwake.start(.turnedOff))

        XCTAssertEqual(keepAwake.hold?.until, .turnedOff)
        XCTAssertEqual(power.held, false, "the display can still sleep")

        clock.advance(by: 24 * 60 * 60)
        XCTAssertTrue(keepAwake.isOn)

        keepAwake.turnOff()
        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
        XCTAssertEqual(releases, [], "a release you trigger has no toast")
    }

    func test_displayChoice_startsFromTheSetting_andIsRememberedAcrossHolds() {
        settings.keepsDisplayOn = true
        makeKeepAwake()
        keepAwake.start()
        XCTAssertEqual(power.held, true)
        keepAwake.turnOff()

        keepAwake.start(keepsDisplayOn: false)
        keepAwake.turnOff()
        keepAwake.start()

        XCTAssertEqual(power.held, false, "the choice made in the app outlives the hold")
        XCTAssertFalse(keepAwake.keepsDisplayOn)
    }

    func test_turningTheDisplayOn_whileOn_keepsTheEndCondition() {
        keepAwake.start(.duration(30 * 60))
        let endsAt = keepAwake.hold?.endsAt
        clock.advance(by: 10 * 60)

        keepAwake.start(keepsDisplayOn: true)

        XCTAssertEqual(power.held, true)
        XCTAssertEqual(keepAwake.hold?.until, .duration(30 * 60))
        XCTAssertEqual(keepAwake.hold?.endsAt, endsAt)
        clock.advance(by: 20 * 60)
        XCTAssertEqual(releases, [.timeUp(30 * 60)])
    }

    func test_untilAgentsFinish_withNothingWorking_doesNotStart() {
        XCTAssertEqual(keepAwake.start(.agentsFinish), .nothingWorking)
        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
    }

    func test_untilAgentsFinish_releasesAfterTheGrace_onceTheCountFallsToZero() {
        working = 2
        keepAwake.start(.agentsFinish)
        working = 1
        keepAwake.activityChanged()
        XCTAssertNil(keepAwake.hold?.graceEndsAt, "one agent is still working")

        working = 0
        keepAwake.activityChanged()
        XCTAssertEqual(keepAwake.hold?.graceEndsAt, clock.now.addingTimeInterval(60))

        clock.advance(by: 59)
        XCTAssertTrue(keepAwake.isOn)
        clock.advance(by: 1)
        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
        XCTAssertEqual(releases, [.agentsFinished])
    }

    func test_workStartingDuringTheGrace_carriesTheHoldOn() {
        working = 1
        keepAwake.start(.agentsFinish)
        working = 0
        keepAwake.activityChanged()
        clock.advance(by: 30)

        working = 1
        keepAwake.activityChanged()
        XCTAssertNil(keepAwake.hold?.graceEndsAt)
        clock.advance(by: 60)
        XCTAssertTrue(keepAwake.isOn, "the first grace no longer ends it")

        working = 0
        keepAwake.activityChanged()
        clock.advance(by: 60)
        XCTAssertEqual(releases, [.agentsFinished], "a fresh grace runs after the second finish")
    }

    func test_aZeroGrace_releasesAsTheLastAgentFinishes() {
        settings.grace = 0
        working = 1
        keepAwake.start(.agentsFinish)
        working = 0
        keepAwake.activityChanged()

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertEqual(releases, [.agentsFinished])
    }

    func test_aTimedHold_releasesWhenItsTimeRunsOut() {
        keepAwake.start(.duration(60 * 60))
        XCTAssertEqual(keepAwake.hold?.endsAt, clock.now.addingTimeInterval(60 * 60))

        clock.advance(by: 60 * 60 - 1)
        XCTAssertTrue(keepAwake.isOn)
        clock.advance(by: 1)

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertEqual(releases, [.timeUp(60 * 60)])
    }

    func test_waking_pastATimedHoldsEnd_releasesAtOnce() {
        keepAwake.start(.duration(60 * 60))
        clock.advance(by: 30 * 60)

        clock.sleep(for: 8 * 60 * 60)
        keepAwake.didWake()

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertEqual(releases, [.timeUp(60 * 60)])
    }

    func test_waking_beforeATimedHoldsEnd_endsItOnTheWallClock() {
        keepAwake.start(.duration(60 * 60))
        clock.advance(by: 10 * 60)
        clock.sleep(for: 20 * 60)
        keepAwake.didWake()

        clock.advance(by: 30 * 60 - 1)
        XCTAssertTrue(keepAwake.isOn)
        clock.advance(by: 1)
        XCTAssertEqual(releases, [.timeUp(60 * 60)], "the nap counts toward the hour")
    }

    func test_waking_pastTheGrace_releasesAtOnce() {
        working = 1
        keepAwake.start(.agentsFinish)
        working = 0
        keepAwake.activityChanged()

        clock.sleep(for: 10 * 60)
        keepAwake.didWake()

        XCTAssertEqual(releases, [.agentsFinished])
    }

    func test_startingAnotherEndCondition_replacesTheTimer() {
        working = 1
        keepAwake.start(.duration(30 * 60))
        keepAwake.start(.agentsFinish)

        clock.advance(by: 2 * 60 * 60)

        XCTAssertEqual(keepAwake.hold?.until, .agentsFinish)
        XCTAssertEqual(releases, [])
    }

    func test_activityChanges_doNotEndAHoldThatIsNotWaitingOnAgents() {
        keepAwake.start(.turnedOff)
        keepAwake.activityChanged()
        clock.advance(by: 120)

        XCTAssertTrue(keepAwake.isOn)
    }

    func test_batteryFallingBelowTheStop_releasesEveryHold() {
        keepAwake.start(.turnedOff)
        battery.report(BatteryReading(isOnBattery: true, percent: 10))
        XCTAssertTrue(keepAwake.isOn, "at the stop is not below it")

        battery.report(BatteryReading(isOnBattery: true, percent: 9))

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
        XCTAssertEqual(releases, [.battery(percent: 9)])
    }

    func test_batteryStop_appliesOnlyOnBattery_andNeverMeansNever() {
        keepAwake.start(.turnedOff)
        battery.report(BatteryReading(isOnBattery: false, percent: 4))
        XCTAssertTrue(keepAwake.isOn, "on power the hold carries on")

        settings.batteryStop = nil
        battery.report(BatteryReading(isOnBattery: true, percent: 4))
        XCTAssertTrue(keepAwake.isOn)
        XCTAssertEqual(releases, [])
    }

    func test_startingBelowTheStop_onBattery_doesNotStart() {
        battery.reading = BatteryReading(isOnBattery: true, percent: 8)

        XCTAssertEqual(keepAwake.start(.duration(60 * 60)), .battery(percent: 8, stop: 10))
        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
    }

    func test_raisingTheStopAboveTheCharge_releasesOnSettingsChange() {
        battery.reading = BatteryReading(isOnBattery: true, percent: 15)
        keepAwake.start(.turnedOff)

        settings.batteryStop = 20
        keepAwake.settingsChanged()

        XCTAssertEqual(releases, [.battery(percent: 15)])
    }

    func test_changingTheDisplaySetting_whileOn_reassertsTheHold() {
        keepAwake.start(.turnedOff)

        settings.keepsDisplayOn = true
        keepAwake.settingsChanged()

        XCTAssertEqual(power.held, true)
        XCTAssertTrue(keepAwake.keepsDisplayOn)
    }

    func test_aChangeInTheAgentCount_isAnnounced_onlyWhenTheCountMoves() {
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .keepAwakeDidChange, object: keepAwake, queue: nil
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        working = 3
        keepAwake.activityChanged()
        keepAwake.activityChanged()
        working = 2
        keepAwake.activityChanged()

        XCTAssertEqual(announcements, 2, "each new count is announced once, a repeat is not")
    }

    func test_aDisplayChoiceMadeWhileOff_isUsedByTheNextStart() {
        keepAwake.setKeepsDisplayOn(true)
        XCTAssertNil(power.held, "choosing the display alone does not hold")

        keepAwake.start(.turnedOff)

        XCTAssertEqual(power.held, true)
    }

    func test_aDisplayChoiceMadeWhileOn_reassertsTheHold_andKeepsTheEndCondition() {
        keepAwake.start(.duration(60 * 60))

        keepAwake.setKeepsDisplayOn(true)

        XCTAssertEqual(power.held, true)
        XCTAssertEqual(keepAwake.hold?.until, .duration(60 * 60))
    }

    func test_everyChange_isAnnounced() {
        let announced = expectation(forNotification: .keepAwakeDidChange, object: keepAwake)
        announced.expectedFulfillmentCount = 2

        keepAwake.start(.turnedOff)
        keepAwake.turnOff()

        wait(for: [announced], timeout: 1)
    }

    private let agent = SurfaceID(raw: 1)
    private let builder = SurfaceID(raw: 2)

    func test_aPaneHold_keepsTheMacAwake_neverTheDisplay() {
        settings.keepsDisplayOn = true
        makeKeepAwake()

        XCTAssertNil(keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil))

        XCTAssertTrue(keepAwake.isOn)
        XCTAssertNil(keepAwake.hold, "the person's hold is not started")
        XCTAssertEqual(power.held, false)
        XCTAssertFalse(keepAwake.holdsDisplay)
        XCTAssertEqual(keepAwake.holdingPanes, ["agent"])
    }

    func test_theDisplay_followsThePersonsHold_overPaneHolds() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil)
        keepAwake.start(keepsDisplayOn: true)
        XCTAssertEqual(power.held, true)

        keepAwake.start(.duration(60))
        clock.advance(by: 60)

        XCTAssertEqual(power.held, false, "the pane still holds the Mac, without the display")
        XCTAssertTrue(keepAwake.isOn)
        XCTAssertEqual(releases, [.timeUp(60)])
    }

    func test_eachPaneHoldEndsOnItsOwn_andTheLastOneLetsTheMacSleep() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil)
        keepAwake.startPaneHold(builder, pane: 8, name: "build", for: nil)

        keepAwake.endPaneHold(agent)
        XCTAssertEqual(keepAwake.holdingPanes, ["build"])
        XCTAssertEqual(power.held, false)

        keepAwake.panesClosed([builder])
        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
        XCTAssertEqual(releases, [], "a pane hold ending has no toast")
    }

    func test_aTimedPaneHold_endsWhenItsTimeRunsOut_andAgainReplacesIt() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: 60)
        clock.advance(by: 30)
        let held = keepAwake.paneHold(of: agent)
        XCTAssertEqual(held.map(keepAwake.secondsLeft), 30)

        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: 60)
        clock.advance(by: 59)
        XCTAssertTrue(keepAwake.isOn, "the second on restarted the minute")
        XCTAssertEqual(keepAwake.paneHolds.count, 1)
        clock.advance(by: 1)

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
    }

    func test_anUntimedOn_replacesATimedPaneHold() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: 60)
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil)

        clock.advance(by: 120)

        XCTAssertTrue(keepAwake.isOn)
        XCTAssertNil(keepAwake.paneHold(of: agent)?.endsAt)
    }

    func test_turnOff_endsThePersonsHoldAndEveryPaneHold() {
        keepAwake.start(.turnedOff)
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: 60)
        keepAwake.startPaneHold(builder, pane: 8, name: "build", for: nil)

        keepAwake.turnOff()
        clock.advance(by: 120)

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertEqual(keepAwake.paneHolds, [])
        XCTAssertNil(power.held)
        XCTAssertEqual(releases, [])
    }

    func test_turnOff_withOnlyPaneHolds_endsThem() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil)

        keepAwake.turnOff()

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertNil(power.held)
    }

    func test_theBatteryStop_refusesAPaneHold_andEndsEveryHold() {
        battery.reading = BatteryReading(isOnBattery: true, percent: 8)
        XCTAssertEqual(
            keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil), .battery(percent: 8, stop: 10))
        XCTAssertFalse(keepAwake.isOn)

        battery.report(BatteryReading(isOnBattery: true, percent: 50))
        keepAwake.start(.turnedOff)
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil)
        battery.report(BatteryReading(isOnBattery: true, percent: 9))

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertEqual(keepAwake.paneHolds, [])
        XCTAssertNil(power.held)
        XCTAssertEqual(releases, [.battery(percent: 9)])
    }

    func test_theBatteryStop_endsPaneHolds_withoutThePersonsHold() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil)

        battery.report(BatteryReading(isOnBattery: true, percent: 9))

        XCTAssertFalse(keepAwake.isOn)
        XCTAssertEqual(releases, [.battery(percent: 9)])
    }

    func test_waking_endsAPaneHoldWhoseTimePassedInSleep_andRearmsTheRest() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: 30 * 60)
        keepAwake.startPaneHold(builder, pane: 8, name: "build", for: 2 * 60 * 60)

        clock.sleep(for: 60 * 60)
        keepAwake.didWake()
        XCTAssertEqual(keepAwake.holdingPanes, ["build"])

        clock.advance(by: 60 * 60 - 1)
        XCTAssertTrue(keepAwake.isOn)
        clock.advance(by: 1)
        XCTAssertFalse(keepAwake.isOn, "the nap counts toward the two hours")
    }

    func test_closingAPaneWithNoHold_announcesNothing() {
        keepAwake.startPaneHold(agent, pane: 7, name: "agent", for: nil)
        let announced = expectation(forNotification: .keepAwakeDidChange, object: keepAwake)
        announced.isInverted = true

        keepAwake.panesClosed([builder])

        wait(for: [announced], timeout: 0.1)
        XCTAssertTrue(keepAwake.isOn)
    }
}
