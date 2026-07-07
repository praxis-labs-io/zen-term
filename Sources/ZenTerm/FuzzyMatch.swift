import Foundation

/// Case-insensitive subsequence fuzzy matching for the command palette. Pure value
/// logic (no AppKit) so it's unit-testable. The repo picker uses a plain `contains`;
/// the command palette wants a ranked fuzzy match instead.
enum FuzzyMatch {
    /// Score of `query` matched as a subsequence of `candidate`, case-insensitive.
    /// Returns `nil` when `query` is not a subsequence. Higher is better: contiguous
    /// runs and word-boundary hits score up, and an earlier first match wins ties.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }  // empty query matches everything, no ranking
        let c = Array(candidate.lowercased())

        var qi = 0
        var score = 0
        var lastMatch = -1
        var firstMatch = -1
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            if firstMatch < 0 { firstMatch = ci }
            score += 1
            if lastMatch == ci - 1 { score += 5 }  // contiguous with the previous match
            if ci == 0 || isBoundary(c[ci - 1]) { score += 8 }  // start of a word
            lastMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }  // ran out of candidate before matching all
        return score - firstMatch  // earlier first match ranks higher on ties
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "/" || ch == "."
    }
}
