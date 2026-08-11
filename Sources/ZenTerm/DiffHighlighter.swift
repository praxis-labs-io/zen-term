import Foundation
import SwiftTreeSitter

/// Turns a whole-file source string into per-line syntax spans. tree-sitter parses whole
/// documents, so we parse the full blob (a bare hunk parses to garbage at its edges) and then map each
/// colored capture onto the file lines it covers. Ranges come out as UTF-16 `NSRange`s aligned to the
/// text, because `SwiftTreeSitter.Parser` parses UTF-16LE and `Node.range` is already UTF-16.
///
/// The parsing and the range→line mapping are separate statics so the mapping is unit-testable on a
/// fixture without a grammar. The off-main orchestration (blob fetch, size ceiling, generation token)
/// lives in the caller.
enum DiffHighlighter {
    /// Skip a side larger than this, so a generated or minified blob can't tie up a parse slot. An
    /// oversized side renders plain.
    ///
    /// **Bytes only, deliberately.** There was a 2000-line ceiling here too, and it was the wrong shape:
    /// parse cost tracks size, not line count, so it fired earlier than the byte cap for ordinary source
    /// while doing nothing extra for the case that actually costs (a few very long lines). Measured on
    /// this repo: 109 KB / 2019 lines of Swift parses in 53.6 ms, 75 KB in 38.7 ms, 9 KB in 7.2 ms, so
    /// roughly 0.5 ms/KB and 256 KB bounds the worst case near 125 ms. All of it runs off the main
    /// thread (`enrich` on a global queue, the prefetcher on its own), so that is latency before a file
    /// paints highlighted, not a hitch.
    ///
    /// The line cap made `WindowController.swift` render permanently plain the day it passed 2000 lines,
    /// which is a bad trade for a guard the byte ceiling already covers.
    private static let maxBytes = 256 * 1024

    /// Resolve the grammar, fetch both sides' whole-file blobs, parse and map them to per-side line spans
    /// — all off the main thread — then hand the result back on main. Returns nil when the language is
    /// unsupported or neither side produced spans, so the caller leaves the file plain. The caller guards
    /// against a stale result (a fast file-switch) with its own generation token.
    static func enrich(file: FileDiff, repoRoot: URL, completion: @escaping (DiffFileSpans?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = enrichSync(file: file, repoRoot: repoRoot)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The synchronous body of `enrich`, for a caller already off-main (the prefetch queue) that shouldn't
    /// pay for another dispatch. Resolve, fetch both sides, parse, map. nil if unsupported or no spans.
    /// When the path alone can't answer, the blob's own content gets a turn: a shebang or modeline names
    /// the language for an extensionless script.
    static func enrichSync(file: FileDiff, repoRoot: URL) -> DiffFileSpans? {
        if let (language, query) = SyntaxLanguage.resolve(path: file.path) {
            return fileSpans(
                old: GitDiffRunner.blobText(for: file, side: .old, repoRoot: repoRoot),
                new: GitDiffRunner.blobText(for: file, side: .new, repoRoot: repoRoot),
                language, query)
        }
        guard SyntaxLanguage.isContentDetectable(path: file.path) else { return nil }
        // Sniff the side the reader is looking at: the new blob, or the old one when the new side is
        // absent (a deletion) or empty (the file was truncated but kept). Keying the fallback on nil
        // alone made an emptied script sniff "" and render plain, while the same file deleted outright
        // highlighted. The old side is fetched lazily, so a config that resolves to nothing, which is
        // most extensionless files, still costs one git spawn rather than two.
        let new = GitDiffRunner.blobText(for: file, side: .new, repoRoot: repoRoot)
        let old =
            (new?.isEmpty ?? true) ? GitDiffRunner.blobText(for: file, side: .old, repoRoot: repoRoot) : nil
        let sniffed = (new?.isEmpty ?? true) ? old : new
        // Detection is cheap but not free, and a blob over the ceiling renders plain whatever it says.
        guard let sniffed, isWithinSizeCeiling(sniffed),
            let (language, query) = SyntaxLanguage.resolve(path: file.path, content: sniffed)
        else { return nil }
        // `old` is nil here only when the new side carried content, so the `??` never repeats a fetch.
        return fileSpans(
            old: old ?? GitDiffRunner.blobText(for: file, side: .old, repoRoot: repoRoot), new: new,
            language, query)
    }

    /// Both sides parsed and mapped, or nil when neither produced spans, leaving the file plain.
    private static func fileSpans(
        old: String?, new: String?, _ language: Language, _ query: Query
    ) -> DiffFileSpans? {
        let oldSpans = sideSpans(old, language, query)
        let newSpans = sideSpans(new, language, query)
        return oldSpans.isEmpty && newSpans.isEmpty ? nil : DiffFileSpans(old: oldSpans, new: newSpans)
    }

    /// Whether a blob is small enough to parse without tying up a slot: under the byte ceiling. A file
    /// over it renders plain. Line count is deliberately not a factor, see `maxBytes`.
    static func isWithinSizeCeiling(_ text: String) -> Bool {
        text.utf8.count <= maxBytes
    }

    /// Per-line spans for one side's blob, or empty when the blob is absent or over the size ceiling.
    private static func sideSpans(_ text: String?, _ language: Language, _ query: Query) -> [Int: [TokenSpan]] {
        guard let text, isWithinSizeCeiling(text) else { return [:] }
        return perLineSpans(text: text, language: language, query: query)
    }

    /// Parse `text` with `language`, run the highlight `query`, and return colored spans keyed by
    /// 1-based file line number. Returns empty on a parse failure.
    static func perLineSpans(text: String, language: Language, query: Query) -> [Int: [TokenSpan]] {
        let parser = Parser()
        do { try parser.setLanguage(language) } catch { return [:] }
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [:] }
        var captures: [(range: NSRange, role: SyntaxRole)] = []
        // Resolve query predicates (`#match?`, `#eq?`, `#is-not?`) instead of taking every syntactic
        // match. 27 of the bundled grammars gate captures behind one, and an unresolved predicate fires
        // regardless: Swift's `((navigation_expression (simple_identifier) @type) (#match? @type "^[A-Z]"))`
        // would tag the base of *every* dotted access (`chrome.background`) as a type, and TypeScript's
        // bare `(identifier) @type` would tag every identifier. `Context(string:)` builds a caching text
        // provider over the same source these ranges index into. Purely subtractive: it can only drop
        // matches whose guard fails, never invent one.
        let resolved = query.execute(node: root, in: tree).resolve(with: Predicate.Context(string: text))
        for match in resolved {
            for capture in match.captures {
                guard let role = SyntaxLanguage.role(forCapture: capture.nameComponents) else { continue }
                let range = capture.node.range
                guard range.length > 0 else { continue }
                captures.append((range, role))
            }
        }
        return perLineSpans(text: text, captures: captures)
    }

    /// Distribute whole-text capture ranges onto the lines they cover, as line-relative spans keyed by
    /// 1-based line number. A capture that crosses a newline (a multiline string or comment) contributes
    /// a clamped span to each line it touches. Pure over its inputs — no grammar needed — so the mapping
    /// is testable directly.
    static func perLineSpans(text: String, captures: [(range: NSRange, role: SyntaxRole)]) -> [Int: [TokenSpan]] {
        let ns = text as NSString
        var lineRanges: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            lineRanges.append(substringRange)
        }
        guard !lineRanges.isEmpty else { return [:] }

        var result: [Int: [TokenSpan]] = [:]
        for (range, role) in captures {
            // Binary-search the first line whose content could still intersect the capture (its end is
            // past the capture's start), then walk forward while lines begin before the capture ends.
            var low = 0
            var high = lineRanges.count
            while low < high {
                let mid = (low + high) / 2
                if lineRanges[mid].location + lineRanges[mid].length <= range.location {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            let rangeEnd = range.location + range.length
            var index = low
            while index < lineRanges.count, lineRanges[index].location < rangeEnd {
                let intersection = NSIntersectionRange(range, lineRanges[index])
                if intersection.length > 0 {
                    let relative = NSRange(
                        location: intersection.location - lineRanges[index].location, length: intersection.length)
                    result[index + 1, default: []].append(TokenSpan(range: relative, role: role))
                }
                index += 1
            }
        }
        return result
    }
}
