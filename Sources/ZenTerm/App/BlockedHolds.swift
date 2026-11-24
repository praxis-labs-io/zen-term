import Foundation

// Holds a message for an agent while it is blocked, since a paste would answer the user's prompt. Main-thread only.
final class BlockedHolds {
    static let recheck: TimeInterval = 1
    static let longestHold: TimeInterval = 600

    var now: () -> Date = Date.init
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hold(by cap: Date, whileBlocked isBlocked: @escaping () -> Bool, then deliver: @escaping () -> Void) {
        guard isBlocked() else { return deliver() }
        guard now() < cap else { return }
        after(Self.recheck) { [weak self] in self?.hold(by: cap, whileBlocked: isBlocked, then: deliver) }
    }
}
