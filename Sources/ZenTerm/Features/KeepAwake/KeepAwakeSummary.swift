import Foundation

// The words the footer and the Keep Awake popover use to say what a hold is and what ends it.
enum KeepAwakeSummary {
    static let batteryWarningMargin = 10

    static func footerDetail(hold: KeepAwake.Hold, activeCount: Int, now: Date) -> String? {
        if let graceEndsAt = hold.graceEndsAt { return "ending in \(seconds(until: graceEndsAt, from: now))s" }
        switch hold.until {
        case .turnedOff: return nil
        case .agentsFinish: return activeCount == 1 ? "1 agent" : "\(activeCount) agents"
        case .duration: return hold.endsAt.map { shortRemaining(until: $0, from: now) }
        }
    }

    static func sentence(hold: KeepAwake.Hold, keepsDisplayOn: Bool, activeCount: Int, now: Date) -> String {
        let subject = keepsDisplayOn ? "Awake and display on" : "Awake"
        let display = keepsDisplayOn ? "" : " The display can still sleep."
        if let graceEndsAt = hold.graceEndsAt {
            return "Agents finished. \(subject) for \(longRemaining(until: graceEndsAt, from: now)).\(display)"
        }
        switch hold.until {
        case .turnedOff:
            return "\(subject) until you turn it off.\(display)"
        case .agentsFinish:
            let agents = activeCount == 1 ? "1 working agent finishes" : "\(activeCount) working agents finish"
            return "\(subject) until \(agents).\(display)"
        case .duration:
            guard let endsAt = hold.endsAt else { return "\(subject).\(display)" }
            let clock = endsAt.formatted(date: .omitted, time: .shortened)
            return "\(subject) for \(longRemaining(until: endsAt, from: now)), until \(clock).\(display)"
        }
    }

    static func isBatteryLow(_ battery: BatteryReading?, stop: Int?) -> Bool {
        guard let battery, let stop, battery.isOnBattery else { return false }
        return battery.percent <= stop + batteryWarningMargin
    }

    static func nextChange(hold: KeepAwake.Hold, now: Date) -> TimeInterval? {
        if let graceEndsAt = hold.graceEndsAt { return untilNextSecond(of: graceEndsAt, from: now) }
        guard let endsAt = hold.endsAt else { return nil }
        let left = endsAt.timeIntervalSince(now)
        guard left > 60 else { return untilNextSecond(of: endsAt, from: now) }
        let intoMinute = left.truncatingRemainder(dividingBy: 60)
        return intoMinute > 0 ? intoMinute : 60
    }

    private static func untilNextSecond(of end: Date, from now: Date) -> TimeInterval {
        let intoSecond = end.timeIntervalSince(now).truncatingRemainder(dividingBy: 1)
        return intoSecond > 0 ? intoSecond : 1
    }

    private static func seconds(until end: Date, from now: Date) -> Int {
        max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    }

    private static func shortRemaining(until end: Date, from now: Date) -> String {
        let left = seconds(until: end, from: now)
        guard left >= 60 else { return "\(left)s" }
        let minutes = (left + 59) / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func longRemaining(until end: Date, from now: Date) -> String {
        let left = seconds(until: end, from: now)
        guard left >= 60 else { return plural(left, "more second") }
        let minutes = (left + 59) / 60
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return plural(rest, "more minute") }
        if rest == 0 { return plural(hours, "more hour") }
        return "\(plural(hours, "hour")) and \(plural(rest, "more minute"))"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
