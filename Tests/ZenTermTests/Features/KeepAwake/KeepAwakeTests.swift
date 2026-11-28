import XCTest

@testable import ZenTerm

final class KeepAwakeTests: XCTestCase {
    private final class FakePower: PowerAssertions {
        var held: Bool?
        var releases = 0

        func hold(keepingDisplayOn: Bool) { held = keepingDisplayOn }

        func release() {
            held = nil
            releases += 1
        }
    }

    private final class FakeBattery: BatterySource {
        var reading: BatteryReading?
        var onChange: (() -> Void)?

        func report(_ reading: BatteryReading?) {
            self.reading = reading
            onChange?()
        }
    }

    private final class FakeClock: KeepAwakeClock {
        private struct Pending {
            let id: Int
            let due: Date
            let fire: () -> Void
        }

        var now = Date(timeIntervalSinceReferenceDate: 0)
        private var pending: [Pending] = []
        private var nextID = 0

        func schedule(after seconds: TimeInterval, _ fire: @escaping () -> Void) -> Cancel {
            nextID += 1
            let id = nextID
            pending.append(Pending(id: id, due: now.addingTimeInterval(seconds), fire: fire))
            return { [weak self] in self?.pending.removeAll { $0.id == id } }
        }

        func advance(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            let due = pending.filter { $0.due <= now }
            pending.removeAll { $0.due <= now }
            due.forEach { $0.fire() }
        }
    }

    private var power: FakePower!
    private var battery: FakeBattery!
    private var clock: FakeClock!
    private var settings = KeepAwake.Settings(keepsDisplayOn: false, batteryStop: 10, grace: 60)
    private var working = 0
    private var releases: [KeepAwake.Release] = []
    private var keepAwake: KeepAwake!

    override func setUp() {
        super.setUp()
        power = FakePower()
        battery = FakeBattery()
        clock = FakeClock()
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

    func test_everyChange_isAnnounced() {
        let announced = expectation(forNotification: .keepAwakeDidChange, object: keepAwake)
        announced.expectedFulfillmentCount = 2

        keepAwake.start(.turnedOff)
        keepAwake.turnOff()

        wait(for: [announced], timeout: 1)
    }
}
