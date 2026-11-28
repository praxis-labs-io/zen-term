import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlAwakeTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var power: FakePowerAssertions!
    private var battery: FakeBatterySource!
    private var clock: FakeKeepAwakeClock!
    private var keepAwake: KeepAwake!
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
        power = FakePowerAssertions()
        battery = FakeBatterySource()
        clock = FakeKeepAwakeClock()
        keepAwake = KeepAwake(
            power: power, battery: battery, clock: clock,
            settings: { KeepAwake.Settings(keepsDisplayOn: true, batteryStop: 10, grace: 60) }, activeCount: { 0 })
    }

    override func tearDownWithError() throws {
        keepAwake.turnOff()
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.keepAwake = keepAwake
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first },
            keepAwake: keepAwake)
    }

    private func send(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int?) throws
        -> ControlReply
    {
        var reply: ControlReply?
        responder.respond(
            to: ControlRequest(id: 1, cmd: cmd, args: args, caller: pane.map { ControlCaller(pane: $0) })
        ) { reply = $0 }
        return try XCTUnwrap(reply, "\(cmd.rawValue) never answered")
    }

    private func awake(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int?) throws
        -> AwakeResult
    {
        let reply = try send(cmd, args, from: pane)
        return try XCTUnwrap(try reply.get() as? AwakeResult, "\(reply)")
    }

    private func error(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int?) throws
        -> ControlError
    {
        guard case .failure(let error) = try send(cmd, args, from: pane) else {
            XCTFail("\(cmd.rawValue) answered OK")
            return ControlError(.failed, "")
        }
        return error
    }

    private func token(of surface: RecordingSurface) throws -> Int {
        try XCTUnwrap(surface.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
    }

    private func twoPanes() throws -> (first: Int, second: Int, secondSurface: RecordingSurface) {
        makeWindow()
        let first = try token(of: try XCTUnwrap(spawned.first))
        _ = try send(.paneSplit, ControlArgs(pane: .token(first), dir: .right), from: nil)
        let second = try XCTUnwrap(spawned.last)
        return (first, try token(of: second), second)
    }

    func test_on_holdsTheMacForTheCallersPane_withoutTheDisplay() throws {
        let panes = try twoPanes()

        let held = try awake(.awakeOn, from: panes.first)

        XCTAssertTrue(held.on)
        XCTAssertFalse(held.user, "the person's hold in the app is not started")
        XCTAssertFalse(held.display, "a pane hold never keeps the display on")
        XCTAssertEqual(power.held, false)
        XCTAssertEqual(held.pane, AwakeResult.Hold(token: panes.first, name: "pane \(panes.first)", remaining: nil))
        XCTAssertEqual(held.panes, [held.pane].compactMap { $0 })

        let seen = try awake(.awakeStatus, from: panes.second)
        XCTAssertTrue(seen.on)
        XCTAssertNil(seen.pane, "the asking pane holds nothing")
        XCTAssertEqual(seen.panes.map(\.token), [panes.first])
        XCTAssertEqual(keepAwake.holdingPanes, ["pane \(panes.first)"])
    }

    func test_off_endsOnlyTheCallersHold() throws {
        let panes = try twoPanes()
        _ = try awake(.awakeOn, from: panes.first)
        _ = try awake(.awakeOn, from: panes.second)

        let after = try awake(.awakeOff, from: panes.first)

        XCTAssertTrue(after.on)
        XCTAssertNil(after.pane)
        XCTAssertEqual(after.panes.map(\.token), [panes.second])

        let none = try awake(.awakeOff, from: panes.second)
        XCTAssertFalse(none.on)
        XCTAssertEqual(none.panes, [])
        XCTAssertNil(power.held)
    }

    func test_for_endsTheHoldWhenItsTimeRunsOut() throws {
        let panes = try twoPanes()

        let held = try awake(.awakeOn, ControlArgs(duration: 90), from: panes.first)
        XCTAssertEqual(held.pane?.remaining, 90)
        clock.advance(by: 30)
        XCTAssertEqual(try awake(.awakeStatus, from: panes.first).pane?.remaining, 60)

        clock.advance(by: 60)

        XCTAssertFalse(try awake(.awakeStatus, from: panes.first).on)
        XCTAssertNil(power.held)
    }

    func test_theHoldEnds_whenItsPaneExits() throws {
        let panes = try twoPanes()
        _ = try awake(.awakeOn, from: panes.second)

        panes.secondSurface.delegate?.surfaceDidExit(panes.secondSurface, code: 0)
        waitUntil(!keepAwake.isOn, "the pane's hold to end with it")

        XCTAssertNil(power.held)
        XCTAssertEqual(try awake(.awakeStatus, from: panes.first).panes, [])
    }

    func test_theHoldEnds_whenItsPaneIsClosed() throws {
        let panes = try twoPanes()
        _ = try awake(.awakeOn, from: panes.second)

        _ = try send(.paneClose, ControlArgs(force: true, pane: .token(panes.second)), from: nil)

        XCTAssertFalse(keepAwake.isOn)
    }

    func test_thePersonTurningKeepAwakeOff_endsPaneHoldsToo() throws {
        let panes = try twoPanes()
        keepAwake.start(.turnedOff)
        _ = try awake(.awakeOn, ControlArgs(duration: 600), from: panes.first)
        let both = try awake(.awakeStatus, from: nil)
        XCTAssertTrue(both.user)
        XCTAssertTrue(both.display)

        keepAwake.turnOff()

        let after = try awake(.awakeStatus, from: panes.first)
        XCTAssertFalse(after.on)
        XCTAssertFalse(after.user)
        XCTAssertEqual(after.panes, [])
    }

    func test_onBelowTheBatteryStop_isRefused() throws {
        let panes = try twoPanes()
        battery.reading = BatteryReading(isOnBattery: true, percent: 8)

        let refused = try error(.awakeOn, from: panes.first)

        XCTAssertEqual(refused.code, .refused)
        XCTAssertEqual(refused.message, "Battery is at 8%, below the 10% stop.")
        XCTAssertFalse(keepAwake.isOn)
    }

    func test_onAndOffNeedACallerPane_andADurationOfASecondOrMore() throws {
        makeWindow()

        XCTAssertEqual(try error(.awakeOn, from: nil).code, .badRequest)
        XCTAssertEqual(try error(.awakeOff, from: nil).code, .badRequest)
        XCTAssertEqual(try error(.awakeOn, from: 9999).code, .notFound)
        let pane = try token(of: try XCTUnwrap(spawned.first))
        XCTAssertEqual(try error(.awakeOn, ControlArgs(duration: 0), from: pane).code, .badRequest)
        XCTAssertEqual(try error(.awakeOn, ControlArgs(duration: Int.max), from: pane).code, .badRequest)
        XCTAssertEqual(
            try awake(.awakeOn, ControlArgs(duration: ControlWire.longestAwakeHold), from: pane).pane?.remaining,
            ControlWire.longestAwakeHold)
        XCTAssertTrue(try awake(.awakeStatus, from: nil).on, "status needs no pane")
    }
}
