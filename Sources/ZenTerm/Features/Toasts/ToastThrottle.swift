import Foundation

struct ToastThrottle<Key: Equatable> {
    // Held chords auto-repeat; without this a leaned-on chord stacks a card per keystroke.
    static var interval: TimeInterval { 3 }

    private var last: (key: Key, at: Date)?

    mutating func allows(_ key: Key, at now: Date = Date()) -> Bool {
        if let last, last.key == key, now.timeIntervalSince(last.at) < Self.interval { return false }
        last = (key, now)
        return true
    }
}

extension ToastThrottle where Key == Bool {
    mutating func allows(at now: Date = Date()) -> Bool { allows(true, at: now) }
}
