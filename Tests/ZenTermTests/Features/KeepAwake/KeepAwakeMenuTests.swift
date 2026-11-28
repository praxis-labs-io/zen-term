import AppKit
import XCTest

@testable import ZenTerm

final class KeepAwakeMenuTests: WindowTestCase {
    private var window: NSWindow!
    private var footer: SidebarFooter!
    private var power: FakePower!
    private var battery: FakeBattery!
    private var clock: FakeClock!
    private var keepAwake: KeepAwake!
    private var menu: KeepAwakeMenu!
    private var settings = KeepAwake.Settings(keepsDisplayOn: false, batteryStop: 10, grace: 60)
    private var working = 0
    private var refusals: [KeepAwake.Refusal] = []
    private var activity: IconButton.Activity?

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { true }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.borderless], backing: .buffered,
            defer: false)
        footer = SidebarFooter(onPalette: {})
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        power = FakePower()
        battery = FakeBattery()
        clock = FakeClock()
        settings = KeepAwake.Settings(keepsDisplayOn: false, batteryStop: 10, grace: 60)
        working = 0
        refusals = []
        activity = nil
        keepAwake = KeepAwake(
            power: power, battery: battery, clock: clock, settings: { [unowned self] in self.settings },
            activeCount: { [unowned self] in self.working })
        menu = KeepAwakeMenu(
            keepAwake: keepAwake, indicator: footer.keepAwakeIndicator, clock: clock,
            onRefused: { [unowned self] in self.refusals.append($0) },
            onActivityChanged: { [unowned self] in self.activity = $0 })
        content.layoutSubtreeIfNeeded()
    }

    override func tearDownWithError() throws {
        menu?.shutdown()
        menu = nil
        keepAwake = nil
        window = nil
        try super.tearDownWithError()
    }

    private var indicator: KeepAwakeIndicator { footer.keepAwakeIndicator }

    private func click(_ view: NSView) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let target = try XCTUnwrap(window.contentView?.hitTest(point), "nothing takes the click")
        XCTAssertTrue(target === view || target.isDescendant(of: view), "the click lands on \(target)")
        try sendClick(to: target, at: point)
    }

    private func openPopover() throws -> PopoverForm {
        try click(indicator)
        XCTAssertTrue(menu.isOpen, "clicking the indicator did not open the popover")
        return try XCTUnwrap(menu.formForTesting)
    }

    private func press(_ key: TypedKey) throws { window.sendEvent(try key.event(in: window)) }

    func test_clickingTheIndicator_opensThePopover_withTheSwitchOff_andNoRowChecked() throws {
        let form = try openPopover()

        XCTAssertEqual(menu.toggleForTesting?.isOn, false)
        XCTAssertNil(form.statusForTesting, "off has no status line")
        XCTAssertEqual(form.rowViewsForTesting.map(\.content.title), KeepAwakeMenu.choices.map(\.title))
        XCTAssertEqual(form.rowViewsForTesting.map(\.content.trailing), [nil, nil, nil, nil, nil])
        XCTAssertEqual(form.rowViewsForTesting[1].content.ink, .faint, "with nothing working, agents is disabled")
    }

    func test_clickingARow_startsThatHold_andThePopoverShowsIt() throws {
        let form = try openPopover()

        try click(form.rowViewsForTesting[3])

        XCTAssertEqual(keepAwake.hold?.until, .duration(60 * 60))
        XCTAssertEqual(power.held, false)
        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(menu.toggleForTesting?.isOn, true, "the switch did not follow the hold")
        XCTAssertEqual(form.rowViewsForTesting.map(\.content.trailing), [nil, nil, nil, .check, nil])
        XCTAssertEqual(form.headerTintForTesting, Theme.current.chrome.accent.nsColor)
        XCTAssertEqual(form.statusForTesting?.hasPrefix("Awake for 1 more hour, until "), true)
        XCTAssertEqual(indicator.detailTextForTesting, "1h")
    }

    func test_theSwitch_endsTheHold() throws {
        keepAwake.start(.turnedOff)
        _ = try openPopover()
        let toggle = try XCTUnwrap(menu.toggleForTesting)
        XCTAssertTrue(toggle.isOn, "precondition")

        try click(toggle)

        XCTAssertFalse(keepAwake.isOn, "the switch did not end the hold")
        XCTAssertNil(power.held)
        XCTAssertNil(menu.formForTesting?.statusForTesting)
        XCTAssertNil(indicator.awakeTextForTesting)
    }

    func test_theSwitch_startsAHoldUntilTurnedOff_withTheDisplayChosenWhileOff() throws {
        _ = try openPopover()
        try click(try XCTUnwrap(menu.scopeForTesting?.subviews.last))
        XCTAssertFalse(keepAwake.isOn, "choosing the display alone does not start a hold")

        try click(try XCTUnwrap(menu.toggleForTesting))

        XCTAssertEqual(keepAwake.hold?.until, .turnedOff)
        XCTAssertEqual(power.held, true, "the display chosen while off was not used")
        XCTAssertTrue(indicator.showsDisplayForTesting)
    }

    func test_aDisplayChoiceMadeWhileOff_isRememberedByKeepAwake_acrossClosingThePopover() throws {
        _ = try openPopover()
        try click(try XCTUnwrap(menu.scopeForTesting?.subviews.last))
        XCTAssertTrue(keepAwake.keepsDisplayOn, "the choice did not reach KeepAwake")
        menu.close()

        _ = try openPopover()
        XCTAssertEqual(menu.scopeForTesting?.selectedIndex, 1, "reopening forgot the display choice")
        keepAwake.start(.turnedOff)
        XCTAssertEqual(power.held, true, "a start from elsewhere did not honor the choice")
    }

    func test_openingAndClosing_reportsEachOnce() throws {
        var reports: [Bool] = []
        menu.onOpenChanged = { reports.append($0) }

        _ = try openPopover()
        NSApp.sendEvent(try TypedKey.escape.event(in: window))
        XCTAssertFalse(menu.isOpen, "precondition: Escape closes the popover")
        _ = try openPopover()
        menu.togglePopover()

        XCTAssertEqual(reports, [true, false, true, false])
    }

    func test_theIndicatorsSpokenValue_includesTheBatteryWarning() {
        keepAwake.start(.turnedOff)
        battery.report(BatteryReading(isOnBattery: true, percent: 20))

        XCTAssertEqual(indicator.accessibilityValue() as? String, "Awake, battery low")
    }

    func test_choosingTheDisplay_whileOn_keepsTheEndCondition() throws {
        working = 2
        keepAwake.start(.agentsFinish)
        _ = try openPopover()

        try click(try XCTUnwrap(menu.scopeForTesting?.subviews.last))

        XCTAssertEqual(keepAwake.hold?.until, .agentsFinish)
        XCTAssertEqual(power.held, true)
    }

    func test_aRefusedStart_goesToTheToast_andTheSwitchStaysOff() throws {
        battery.report(BatteryReading(isOnBattery: true, percent: 5))
        _ = try openPopover()

        try click(try XCTUnwrap(menu.toggleForTesting))

        XCTAssertEqual(refusals, [.battery(percent: 5, stop: 10)])
        XCTAssertEqual(menu.toggleForTesting?.isOn, false, "the switch shows on for a hold that never started")
    }

    func test_offWithAgentsWorking_highlightsUntilAgentsFinish_andShowsTheCount() throws {
        working = 3
        keepAwake.activityChanged()
        let form = try openPopover()

        XCTAssertEqual(form.highlightedRow, 1)
        XCTAssertEqual(form.rowViewsForTesting[1].content.note, "3 working")
        try press(.returnKey)
        XCTAssertEqual(keepAwake.hold?.until, .agentsFinish)
    }

    func test_tab_walksTheSwitch_theDisplayChoice_thenTheRows() throws {
        let form = try openPopover()

        try press(.tab)
        XCTAssertTrue(window.firstResponder === menu.toggleForTesting, "Tab from the rows did not reach the switch")
        try press(.tab)
        XCTAssertTrue(window.firstResponder === menu.scopeForTesting)
        try press(.tab)
        XCTAssertTrue(window.firstResponder === form)
    }

    func test_clickingTheIndicatorAgain_closesThePopover() throws {
        _ = try openPopover()
        XCTAssertTrue(indicator.isActive)

        menu.togglePopover()

        XCTAssertFalse(menu.isOpen)
        XCTAssertFalse(indicator.isActive)
    }

    func test_theIndicator_showsEachState() throws {
        XCTAssertNil(indicator.awakeTextForTesting, "off is a bare cup")
        XCTAssertEqual(indicator.cupTintForTesting, Theme.current.chrome.ink(.subtle))

        keepAwake.start(.turnedOff)
        XCTAssertEqual(indicator.awakeTextForTesting, "Awake")
        XCTAssertNil(indicator.detailTextForTesting)
        XCTAssertEqual(indicator.cupTintForTesting, Theme.current.chrome.accent.nsColor)
        XCTAssertFalse(indicator.showsDisplayForTesting)

        working = 3
        keepAwake.start(.agentsFinish, keepsDisplayOn: true)
        XCTAssertEqual(indicator.detailTextForTesting, "3 agents")
        XCTAssertTrue(indicator.showsDisplayForTesting)

        working = 2
        keepAwake.activityChanged()
        XCTAssertEqual(indicator.detailTextForTesting, "2 agents", "the count did not follow the agents")

        working = 0
        keepAwake.activityChanged()
        XCTAssertEqual(indicator.detailTextForTesting, "ending in 60s")
        clock.advance(by: 15)
        XCTAssertEqual(indicator.detailTextForTesting, "ending in 45s", "the grace did not count down")
    }

    func test_aTimedHold_ticksByTheMinute_thenBySecond() throws {
        keepAwake.start(.duration(30 * 60))
        XCTAssertEqual(indicator.detailTextForTesting, "30m")

        clock.advance(by: 60)
        XCTAssertEqual(indicator.detailTextForTesting, "29m")

        clock.advance(by: 27 * 60)
        XCTAssertEqual(indicator.detailTextForTesting, "2m")
        clock.advance(by: 60)
        XCTAssertEqual(indicator.detailTextForTesting, "1m", "the last minute skipped 1m")
        clock.advance(by: 1)
        XCTAssertEqual(indicator.detailTextForTesting, "59s")
    }

    func test_nearTheBatteryStop_theCupAndTheDotTurnWarning() throws {
        keepAwake.start(.turnedOff)
        XCTAssertEqual(activity, .live)

        battery.report(BatteryReading(isOnBattery: true, percent: 20))

        XCTAssertEqual(indicator.cupTintForTesting, Theme.current.chrome.warning.nsColor)
        XCTAssertEqual(activity, .warning)

        keepAwake.turnOff()
        XCTAssertNil(activity, "the dot stayed after the hold ended")
    }
}
