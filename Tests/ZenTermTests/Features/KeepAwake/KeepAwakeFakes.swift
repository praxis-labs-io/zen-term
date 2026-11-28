import Foundation

@testable import ZenTerm

final class FakePowerAssertions: PowerAssertions {
    var held: Bool?
    var releases = 0

    func hold(keepingDisplayOn: Bool) { held = keepingDisplayOn }

    func release() {
        held = nil
        releases += 1
    }
}

final class FakeBatterySource: BatterySource {
    var reading: BatteryReading?
    var onChange: (() -> Void)?

    func report(_ reading: BatteryReading?) {
        self.reading = reading
        onChange?()
    }
}

final class FakeKeepAwakeClock: KeepAwakeClock {
    private struct Pending {
        let id: Int
        var due: Date
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

    func sleep(for seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for index in pending.indices { pending[index].due.addTimeInterval(seconds) }
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = pending.filter { $0.due <= now }
        pending.removeAll { $0.due <= now }
        due.forEach { $0.fire() }
    }
}
