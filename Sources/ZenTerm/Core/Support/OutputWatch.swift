// libghostty reports no output, so new text is found by lining each read of a pane's tail up with the one before it.
struct OutputWatch {
    let needle: String
    private var previous: [String]

    init(needle: String, baseline: String) {
        self.needle = needle
        previous = Self.lines(baseline)
    }

    mutating func sawNeedle(in tail: String) -> Bool {
        let current = Self.lines(tail)
        defer { previous = current }
        let (fresh, before) = Self.arrived(current, since: previous)
        return Self.count(needle, in: fresh) > Self.count(needle, in: before)
    }

    // The top line of a read can be the cut-off end of a wrapped line, and the last is where the cursor writes.
    private static func arrived(_ current: [String], since previous: [String]) -> (fresh: [String], before: [String]) {
        guard previous.count >= 3, current.count >= 2 else { return (current, previous) }
        let settled = previous.dropFirst().dropLast()
        let body = current.dropFirst()
        for scrolled in 0..<settled.count {
            let kept = settled.dropFirst(scrolled)
            guard kept.contains(where: { !$0.allSatisfy(\.isWhitespace) }) else { break }
            if body.starts(with: kept) { return (Array(body.dropFirst(kept.count)), [previous[previous.count - 1]]) }
        }
        return (current, previous)
    }

    private static func count(_ needle: String, in lines: [String]) -> Int {
        lines.joined(separator: "\n").components(separatedBy: needle).count - 1
    }

    private static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines
    }
}
