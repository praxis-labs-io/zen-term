import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// Resolves a file path to a tree-sitter grammar + compiled highlight query (ZEN-239), and maps a
/// query capture name to one of ZEN-238's `SyntaxRole`s. Thin façade over `CodeEditLanguages`, which
/// bundles the grammars (incl. Swift) and their `highlights.scm` — so the engine never vendors a
/// `parser.c`. Keyed off `FileDiff.path`'s extension.
enum SyntaxLanguage {
    /// Compiled-query cache, keyed by tree-sitter grammar name. `resolve` runs on concurrent background
    /// queues — one per prefetching file — and compiling a `Query` means loading `highlights.scm` off
    /// disk and parsing it, expensive enough that every file of a language paying it again is its own
    /// small hitch. `Language` and `Query` are both `Sendable` and safe to read from many threads at once
    /// (a `Query` hands out a fresh `QueryCursor` per `execute`, so it holds no per-call mutable state);
    /// only this dictionary needs guarding. A cached `nil` means "no bundled query for this grammar", so
    /// an unsupported language is looked up once, not once per file. Mirrors `AppLog`'s logger cache.
    private static let cacheLock = NSLock()
    private static var cache: [String: (language: Language, query: Query)?] = [:]

    /// The grammar + highlight query for a path, or nil when the language isn't supported (or has no
    /// bundled query) — the caller renders that file plain.
    ///
    /// The grammar comes from `CodeEditLanguages` (the linked tree-sitter parser), but the highlight
    /// query is loaded from *our* resource bundle: `CodeEditLanguages`' own query loader builds its
    /// `Bundle.module` path wrong under terminal-native SwiftPM (a doubled `Resources/Resources`), and
    /// the app already avoids `Bundle.module` for exactly this class of bug (`ZenTermResources`).
    static func resolve(path: String) -> (language: Language, query: Query)? {
        let code = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path))
        guard code.id != .plainText, let language = code.language else { return nil }
        return resolvedQuery(tsName: code.tsName, language: language)
    }

    /// Get-or-create the cached grammar/query pair, compiling on a miss. Holds `cacheLock` across the
    /// compile (a single small bundled `.scm` — microseconds), trading a little contention on the rare
    /// first resolve of a language for never compiling the same query twice.
    private static func resolvedQuery(tsName: String, language: Language) -> (language: Language, query: Query)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[tsName] { return cached }
        let resolved = highlightQuery(tsName: tsName, language: language).map { (language, $0) }
        cache[tsName] = resolved
        return resolved
    }

    /// Whether a path will highlight — a known language with a bundled query — without loading or
    /// compiling anything. Cheap enough for the main thread: extension detection plus a bundle URL
    /// lookup. Lets the viewer decide up front whether to wait for a highlight or paint plain now.
    static func isSupported(path: String) -> Bool {
        let code = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path))
        return code.id != .plainText && queryURL(tsName: code.tsName) != nil
    }

    private static func queryURL(tsName: String) -> URL? {
        ZenTermResources.bundle.url(
            forResource: "highlights", withExtension: "scm", subdirectory: "SyntaxQueries/tree-sitter-\(tsName)")
    }

    /// Load and compile the bundled `highlights.scm` for a grammar from the app's resource bundle.
    private static func highlightQuery(tsName: String, language: Language) -> Query? {
        guard let url = queryURL(tsName: tsName), let data = try? Data(contentsOf: url) else { return nil }
        return try? Query(language: language, data: data)
    }

    /// Maps a tree-sitter highlight capture (e.g. `keyword.function`, `string`, `punctuation.bracket`)
    /// to a `SyntaxRole`, keyed on the capture's first component. Captures with no role (identifiers,
    /// properties, variables) return nil and render in the base foreground.
    static func role(forCapture nameComponents: [String]) -> SyntaxRole? {
        guard let head = nameComponents.first else { return nil }
        switch head {
        case "keyword", "conditional", "repeat", "include", "boolean": return .keyword
        case "string", "character": return .string
        case "comment": return .comment
        case "number", "float", "constant": return .number
        case "type", "constructor": return .type
        case "function", "method": return .function
        case "operator", "punctuation", "delimiter": return .punctuation
        default: return nil
        }
    }
}
