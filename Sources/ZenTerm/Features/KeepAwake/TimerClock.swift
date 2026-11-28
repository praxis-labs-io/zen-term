import Foundation

final class TimerClock: KeepAwakeClock {
    var now: Date { Date() }

    // Common modes, so a timer due while a menu or a drag tracks still fires.
    func schedule(after seconds: TimeInterval, _ fire: @escaping () -> Void) -> Cancel {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
