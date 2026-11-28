import Foundation

extension Notification.Name {
    static let keepAwakeDidChange = Notification.Name("ZenTerm.keepAwakeDidChange")
}

// The app's hold on idle sleep: the person's own, and one per pane that asked for it with `zen awake`.
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

    struct PaneHold: Equatable {
        let surface: SurfaceID
        let pane: Int
        let name: String
        let endsAt: Date?
    }

    struct Settings: Equatable {
        var keepsDisplayOn: Bool
        var batteryStop: Int?
        var grace: TimeInterval
    }

    private(set) var hold: Hold?
    private(set) var paneHolds: [PaneHold] = []
    private(set) var keepsDisplayOn: Bool
    var onRelease: ((Release) -> Void)?

    private let power: PowerAssertions
    private let batterySource: BatterySource
    private let clock: KeepAwakeClock
    private let settings: () -> Settings
    private let count: () -> Int
    private var seenDisplaySetting: Bool
    private var cancelTimer: KeepAwakeClock.Cancel?
    private var cancelGrace: KeepAwakeClock.Cancel?
    private var cancelPaneTimers: [SurfaceID: KeepAwakeClock.Cancel] = [:]

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

    var isOn: Bool { hold != nil || !paneHolds.isEmpty }

    var holdingPanes: [String] { paneHolds.map(\.name) }

    var holdsDisplay: Bool { hold != nil && keepsDisplayOn }

    var activeCount: Int { count() }

    var battery: BatteryReading? { batterySource.reading }

    var batteryStop: Int? { settings().batteryStop }

    @discardableResult
    func start(_ until: Until? = nil, keepsDisplayOn display: Bool? = nil) -> Refusal? {
        if until == .agentsFinish, count() == 0 { return .nothingWorking }
        if let percent = percentBelowStop(), let stop = batteryStop { return .battery(percent: percent, stop: stop) }
        if let display { keepsDisplayOn = display }
        if until != nil || hold == nil { begin(until ?? .turnedOff) }
        applyPower()
        announce()
        return nil
    }

    func turnOff() {
        guard isOn else { return }
        endEverything()
    }

    @discardableResult
    func startPaneHold(_ surface: SurfaceID, pane: Int, name: String, for duration: TimeInterval?) -> Refusal? {
        if let percent = percentBelowStop(), let stop = batteryStop { return .battery(percent: percent, stop: stop) }
        cancelPaneTimers.removeValue(forKey: surface)?()
        let held = PaneHold(
            surface: surface, pane: pane, name: name, endsAt: duration.map { clock.now.addingTimeInterval($0) })
        if let index = paneHolds.firstIndex(where: { $0.surface == surface }) {
            paneHolds[index] = held
        } else {
            paneHolds.append(held)
        }
        if let duration { armPaneTimer(surface, after: duration) }
        applyPower()
        announce()
        return nil
    }

    func endPaneHold(_ surface: SurfaceID) { panesClosed([surface]) }

    func panesClosed(_ surfaces: [SurfaceID]) {
        let ending = Set(surfaces)
        guard paneHolds.contains(where: { ending.contains($0.surface) }) else { return }
        ending.forEach { cancelPaneTimers.removeValue(forKey: $0)?() }
        paneHolds.removeAll { ending.contains($0.surface) }
        applyPower()
        announce()
    }

    func paneHold(of surface: SurfaceID) -> PaneHold? { paneHolds.first { $0.surface == surface } }

    func secondsLeft(_ held: PaneHold) -> Int? {
        held.endsAt.map { Int(min(max(0, $0.timeIntervalSince(clock.now).rounded(.up)), Double(Int32.max))) }
    }

    func activityChanged() {
        guard var current = hold, current.until == .agentsFinish else { return }
        if count() > 0 {
            guard current.graceEndsAt != nil else { return }
            cancelGrace?()
            cancelGrace = nil
            current.graceEndsAt = nil
            hold = current
            announce()
            return
        }
        guard current.graceEndsAt == nil else { return }
        let grace = settings().grace
        guard grace > 0 else { return release(.agentsFinished) }
        current.graceEndsAt = clock.now.addingTimeInterval(grace)
        hold = current
        armGrace(after: grace)
        announce()
    }

    // A run-loop timer pauses while the Mac sleeps, so a lid closed mid-hold would stretch the hold by the nap.
    func didWake() {
        wakePaneHolds()
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
            if isOn { applyPower() }
        }
        if isOn, let percent = percentBelowStop() { return releaseEverything(.battery(percent: percent)) }
        announce()
    }

    private func batteryChanged() {
        if isOn, let percent = percentBelowStop() { return releaseEverything(.battery(percent: percent)) }
        announce()
    }

    private func wakePaneHolds() {
        let now = clock.now
        let over = paneHolds.filter { $0.endsAt.map { $0 <= now } ?? false }.map(\.surface)
        for held in paneHolds where !over.contains(held.surface) {
            guard let endsAt = held.endsAt else { continue }
            armPaneTimer(held.surface, after: endsAt.timeIntervalSince(now))
        }
        panesClosed(over)
    }

    private func armPaneTimer(_ surface: SurfaceID, after seconds: TimeInterval) {
        cancelPaneTimers.removeValue(forKey: surface)?()
        cancelPaneTimers[surface] = clock.schedule(after: seconds) { [weak self] in
            MainActor.assumeIsolated { self?.endPaneHold(surface) }
        }
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
        cancelTimers()
        hold = nil
        applyPower()
        announce()
        onRelease?(reason)
    }

    private func releaseEverything(_ reason: Release) {
        endEverything()
        onRelease?(reason)
    }

    private func endEverything() {
        cancelTimers()
        cancelPaneTimers.values.forEach { $0() }
        cancelPaneTimers = [:]
        hold = nil
        paneHolds = []
        applyPower()
        announce()
    }

    // A pane hold keeps the Mac awake, never the display: only the person's own hold carries the display choice.
    private func applyPower() {
        if hold != nil {
            power.hold(keepingDisplayOn: keepsDisplayOn)
        } else if !paneHolds.isEmpty {
            power.hold(keepingDisplayOn: false)
        } else {
            power.release()
        }
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
