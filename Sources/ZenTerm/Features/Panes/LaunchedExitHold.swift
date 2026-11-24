import Foundation

/// Holds the close of a pane whose program's exit closes it until the shell's exit mark brings its code.
struct LaunchedExitHold<Key: Hashable> {
    static var tailLines: Int { 40 }
    // The shell's D mark can trail the child's exit, so a launched pane waits this long for its exit code.
    static var markGrace: TimeInterval { 0.25 }

    private var closing: Set<Key> = []
    private var codes: [Key: Int] = [:]
    private var exits: [Key: String?] = [:]

    mutating func watch(_ key: Key) { closing.insert(key) }

    func closesOnExit(_ key: Key) -> Bool { closing.contains(key) }

    func hasExited(_ key: Key) -> Bool { exits.keys.contains(key) }

    func hasMark(_ key: Key) -> Bool { codes[key] != nil }

    mutating func recordMark(_ key: Key, exitCode: Int?) {
        if closing.contains(key) { codes[key] = exitCode }
    }

    mutating func recordExit(_ key: Key, lastLines: String?) { exits[key] = .some(lastLines) }

    // Removes the exit as it hands it over, so a late mark and the grace cannot both report it.
    mutating func take(_ key: Key) -> (exitCode: Int?, lastLines: String?)? {
        guard let lastLines = exits.removeValue(forKey: key) else { return nil }
        return (codes[key], lastLines)
    }

    mutating func forget(_ key: Key) {
        closing.remove(key)
        codes[key] = nil
        exits[key] = nil
    }
}
