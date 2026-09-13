import Foundation

enum FuzzyMatch {
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())

        var qi = 0
        var score = 0
        var lastMatch = -1
        var firstMatch = -1
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            if firstMatch < 0 { firstMatch = ci }
            score += 1
            if lastMatch >= 0 && lastMatch == ci - 1 { score += 5 }
            if ci == 0 || isBoundary(c[ci - 1]) { score += 8 }
            lastMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score - firstMatch
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "/" || ch == "."
    }
}
