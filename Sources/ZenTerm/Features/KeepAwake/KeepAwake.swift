import Foundation

extension Notification.Name {
    static let keepAwakeDidChange = Notification.Name("ZenTerm.keepAwakeDidChange")
}

// The app's one hold on idle sleep, ended by you, a timer, the agents finishing or the battery stop.
@MainActor
final class KeepAwake {
    enum Until: Equatable {
        case turnedOff, agentsFinish
        case duration(TimeInterval)
    }

    // Only the ends you did not trigger: turning it off yourself has no release.
    enum Release: Equatable {
        case agentsFinished
        case timeUp(TimeInterval)
        case battery(percent: Int)
    }

    enum Refusal: Equatable {
        case nothingWorking
        case battery(percent: Int, stop: Int)
    }

    struct Hold: Equatable {
        let until: Until
        let endsAt: Date?
        fileprivate(set) var graceEndsAt: Date?
    }

    struct Settings: Equatable {
        var keepsDisplayOn: Bool
        var batteryStop: Int?
        var grace: TimeInterval
    }

    private(set) var hold: Hold?
    private(set) var keepsDisplayOn: Bool
    var onRelease: ((Release) -> Void)?

    private let power: PowerAssertions
    private let batterySource: BatterySource
    private let clock: KeepAwakeClock
    private let settings: () -> Settings
    private let count: () -> Int
    private var seenDisplaySetting: Bool
    private var lastCount = 0
    private var cancelTimer: KeepAwakeClock.Cancel?
    private var cancelGrace: KeepAwakeClock.Cancel?

    init(
        power: PowerAssertions, battery: BatterySource, clock: KeepAwakeClock,
        settings: @escaping () -> Settings, activeCount: @escaping () -> Int
    ) {
        self.power = power
        batterySource = battery
        self.clock = clock
        self.settings = settings
        count = activeCount
        seenDisplaySetting = settings().keepsDisplayOn
        keepsDisplayOn = seenDisplaySetting
        battery.onChange = { [weak self] in MainActor.assumeIsolated { self?.batteryChanged() } }
    }

    var isOn: Bool { hold != nil }

    var activeCount: Int { count() }

    var battery: BatteryReading? { batterySource.reading }

    var batteryStop: Int? { settings().batteryStop }

    @discardableResult
    func start(_ until: Until? = nil, keepsDisplayOn display: Bool? = nil) -> Refusal? {
        if until == .agentsFinish, count() == 0 { return .nothingWorking }
        if let percent = percentBelowStop(), let stop = batteryStop { return .battery(percent: percent, stop: stop) }
        if let display { keepsDisplayOn = display }
        if until != nil || hold == nil { begin(until ?? .turnedOff) }
        power.hold(keepingDisplayOn: keepsDisplayOn)
        announce()
        return nil
    }

    func turnOff() {
        guard hold != nil else { return }
        end()
    }

    func activityChanged() {
        let active = count()
        let countChanged = active != lastCount
        lastCount = active
        if !followAgents(active: active), countChanged { announce() }
    }

    // A run-loop timer pauses while the Mac sleeps, so a lid closed mid-hold would stretch the hold by the nap.
    func didWake() {
        guard let current = hold else { return }
        let now = clock.now
        if let endsAt = current.endsAt, let duration = current.until.duration {
            guard endsAt > now else { return release(.timeUp(duration)) }
            armTimer(after: endsAt.timeIntervalSince(now), duration: duration)
        }
        if let graceEndsAt = current.graceEndsAt {
            guard graceEndsAt > now else { return release(.agentsFinished) }
            armGrace(after: graceEndsAt.timeIntervalSince(now))
        }
    }

    func settingsChanged() {
        let display = settings().keepsDisplayOn
        if display != seenDisplaySetting {
            seenDisplaySetting = display
            keepsDisplayOn = display
            if hold != nil { power.hold(keepingDisplayOn: display) }
        }
        if hold != nil, let percent = percentBelowStop() { return release(.battery(percent: percent)) }
        announce()
    }

    private func followAgents(active: Int) -> Bool {
        guard var current = hold, current.until == .agentsFinish else { return false }
        if active > 0 {
            guard current.graceEndsAt != nil else { return false }
            cancelGrace?()
            cancelGrace = nil
            current.graceEndsAt = nil
            hold = current
            announce()
            return true
        }
        guard current.graceEndsAt == nil else { return false }
        let grace = settings().grace
        guard grace > 0 else {
            release(.agentsFinished)
            return true
        }
        current.graceEndsAt = clock.now.addingTimeInterval(grace)
        hold = current
        armGrace(after: grace)
        announce()
        return true
    }

    private func batteryChanged() {
        if hold != nil, let percent = percentBelowStop() { return release(.battery(percent: percent)) }
        announce()
    }

    private func begin(_ until: Until) {
        cancelTimers()
        let duration = until.duration
        hold = Hold(until: until, endsAt: duration.map { clock.now.addingTimeInterval($0) }, graceEndsAt: nil)
        guard let duration else { return }
        armTimer(after: duration, duration: duration)
    }

    private func armTimer(after seconds: TimeInterval, duration: TimeInterval) {
        cancelTimer?()
        cancelTimer = clock.schedule(after: seconds) { [weak self] in
            MainActor.assumeIsolated { self?.release(.timeUp(duration)) }
        }
    }

    private func armGrace(after seconds: TimeInterval) {
        cancelGrace?()
        cancelGrace = clock.schedule(after: seconds) { [weak self] in
            MainActor.assumeIsolated { self?.release(.agentsFinished) }
        }
    }

    private func release(_ reason: Release) {
        end()
        onRelease?(reason)
    }

    private func end() {
        cancelTimers()
        hold = nil
        power.release()
        announce()
    }

    private func cancelTimers() {
        cancelTimer?()
        cancelGrace?()
        cancelTimer = nil
        cancelGrace = nil
    }

    private func percentBelowStop() -> Int? {
        guard let stop = batteryStop, let reading = battery, reading.isOnBattery, reading.percent < stop else {
            return nil
        }
        return reading.percent
    }

    private func announce() {
        NotificationCenter.default.post(name: .keepAwakeDidChange, object: self)
    }
}

extension KeepAwake.Until {
    var duration: TimeInterval? {
        if case .duration(let seconds) = self { return seconds }
        return nil
    }
}

extension KeepAwake.Settings {
    init(_ config: GeneralConfig) {
        self.init(
            keepsDisplayOn: config.keepAwakeDisplay, batteryStop: config.keepAwakeBatteryStop,
            grace: config.keepAwakeGrace)
    }
}
