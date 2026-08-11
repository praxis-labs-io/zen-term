import AppLog
import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// Resolves a file path to a tree-sitter grammar + compiled highlight query, and maps a
/// query capture name to one of the `SyntaxRole`s. Thin façade over `CodeEditLanguages`, which
/// bundles the grammars (incl. Swift) and their `highlights.scm` — so the engine never vendors a
/// `parser.c`. Keyed off `FileDiff.path`'s extension (or well-known filename), with the blob's own
/// shebang or modeline breaking the tie for an extensionless file.
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
    /// bundled query), in which case the caller renders that file plain. `content` is the blob's text,
    /// when the caller has it: it feeds shebang and modeline detection for a path the extension table
    /// can't answer. Nothing beyond those two signals is sniffed. An ambiguous key=value
    /// config maps to no grammar correctly, so it deliberately stays plain.
    ///
    /// The grammar comes from `CodeEditLanguages` (the linked tree-sitter parser), but the highlight
    /// query is loaded from *our* resource bundle: `CodeEditLanguages`' own query loader builds its
    /// `Bundle.module` path wrong under terminal-native SwiftPM (a doubled `Resources/Resources`), and
    /// the app already avoids `Bundle.module` for exactly this class of bug (`ZenTermResources`).
    static func resolve(path: String, content: String? = nil) -> (language: Language, query: Query)? {
        guard let code = detected(path: path, content: content), let language = code.language else {
            return nil
        }
        return resolvedQuery(tsName: code.tsName, language: language)
    }

    /// The language for a path, then for its content, or nil for neither. The single funnel both
    /// `resolve` and `isSupported` go through, so the two can't disagree about a path: an alias the
    /// gate didn't know about would leave a file that `resolve` can highlight filtered out before it
    /// ever got the chance.
    private static func detected(path: String, content: String?) -> CodeLanguage? {
        if let byPath = pathLanguage(path) { return byPath }
        guard let content else { return nil }
        let (prefix, suffix) = detectionBuffers(content)
        let code = CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: path), prefixBuffer: prefix, suffixBuffer: suffix)
        if code.id != .plainText { return code }
        return prefix.flatMap(aliasedInterpreter)
    }

    /// The language the path alone names, falling back to our alias table when the package's own
    /// extension table comes back plainText. `setup.zsh` is the commonest way a zsh file is named and
    /// the package knows `sh` and `bash` only.
    private static func pathLanguage(_ path: String) -> CodeLanguage? {
        let code = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path))
        if code.id != .plainText { return code }
        return aliases[URL(fileURLWithPath: path).pathExtension.lowercased()]
    }

    /// Whether the path alone can't answer but the blob's content might: no extension, so a shebang
    /// or modeline is the only signal. A path with an *unknown* extension is not detectable, because
    /// the extension is itself a real answer and it says plain. The prefetcher uses this to widen what
    /// it warms, and orders these behind the certainties.
    static func isContentDetectable(path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.isEmpty && !isSupported(path: path)
    }

    /// Whether a path is worth handing to the highlighter at all: its extension names a language, or it
    /// has no extension and its blob might. The viewer's single gate, so an extensionless script reaches
    /// `enrich` while a `.xyzzy` file is refused up front.
    ///
    /// Equivalent to `isSupported || isContentDetectable`, and deliberately written as the reduced form:
    /// `isContentDetectable` re-tests `isSupported` internally, so the disjunction evaluated it twice per
    /// render for exactly the extensionless paths this exists to admit. That is a `getcwd`, a walk of
    /// `allLanguages` and a bundle lookup, on the main thread.
    static func mayHighlight(path: String) -> Bool {
        isSupported(path: path) || URL(fileURLWithPath: path).pathExtension.isEmpty
    }

    /// How much of the blob's head and tail the two content signals can need. A shebang is line 1 and
    /// editors keep modelines within a handful of lines of either end, so this is generous.
    ///
    /// **Bounded by characters, not by lines.** Splitting the whole blob to keep five lines allocated a
    /// `Substring` per line of the entire file, and it ran ahead of `DiffHighlighter.maxBytes`, the
    /// ceiling that exists to bound exactly this work. A blob with no newline at all (a minified
    /// bundle) handed the whole string to the modeline regexes.
    private static let detectionByteBudget = 4 * 1024

    /// The head and tail of the blob, each capped at `detectionByteBudget`, trimmed to whole lines so a
    /// half-line can't look like a modeline. nil content means the caller had no blob to offer.
    static func detectionBuffers(_ content: String?) -> (prefix: String?, suffix: String?) {
        guard let content else { return (nil, nil) }
        guard content.count > detectionByteBudget else { return (content, nil) }
        let head = String(content.prefix(detectionByteBudget))
        let tail = String(content.suffix(detectionByteBudget))
        // Drop the partial line at each cut so neither buffer starts or ends mid-token.
        let prefix = head.lastIndex(where: \.isNewline).map { String(head[head.startIndex..<$0]) } ?? head
        let suffix = tail.firstIndex(where: \.isNewline).map { String(tail[tail.index(after: $0)...]) } ?? tail
        return (prefix, suffix)
    }

    /// Languages `CodeEditLanguages`' tables don't list, mapped to the grammar that parses them. zsh is
    /// close enough to bash that bash's grammar highlights a zsh script correctly, and the dependency
    /// knows `sh` and `bash` only. Its tables aren't ours to edit, so the shim lives here.
    private static let aliases: [String: CodeLanguage] = ["zsh": .bash]

    /// Resolve the `#!/bin/zsh` and `#!/usr/bin/env zsh` shapes the package's own matcher misses. Mirrors
    /// its parse: the interpreter is the first token's last path component, or after `env`, the next
    /// token that is neither an option (`-S`) nor an assignment (`FOO=bar`).
    ///
    /// Splits on `isNewline` and `isWhitespace`, never on `"\n"` and `" "`. Swift treats `\r\n` as one
    /// grapheme cluster, so splitting on `"\n"` does not split a CRLF file at all: the first line
    /// swallowed the rest of the blob and the interpreter came out as `zsh\r\necho`.
    private static func aliasedInterpreter(_ prefix: String) -> CodeLanguage? {
        guard let firstLine = prefix.split(whereSeparator: \.isNewline).first, firstLine.hasPrefix("#!")
        else { return nil }
        let tokens = firstLine.dropFirst(2).split(whereSeparator: \.isWhitespace)
        guard var interpreter = tokens.first?.split(separator: "/").last else { return nil }
        if interpreter == "env" {
            guard
                let next = tokens.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.contains("=") }),
                let name = next.split(separator: "/").last
            else { return nil }
            interpreter = name
        }
        return aliases[interpreter.lowercased()]
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
        // Must agree with `resolve` on all three conditions, grammar included: a language whose id is
        // known but whose grammar pointer is nil would otherwise be called supported, and the viewer
        // would withhold the first paint for the full safety cap waiting on a highlight that can never
        // arrive. Cheap: `language` is a pointer switch, no I/O. `pathLanguage` is what keeps the two
        // in step, alias table included.
        guard let code = pathLanguage(path), code.language != nil else { return false }
        return queryURL(tsName: code.tsName) != nil
    }

    private static func queryURL(tsName: String) -> URL? {
        ZenTermResources.bundle.url(
            forResource: "highlights", withExtension: "scm", subdirectory: "SyntaxQueries/tree-sitter-\(tsName)")
    }

    /// Grammars that are supersets of another one. Their bundled query carries only the *additions* —
    /// TypeScript's has types and `interface`/`abstract` but no string/comment/function patterns, and
    /// C++'s has templates but not C's basics — so the parent's query is concatenated first or the
    /// language highlights sparsely. Parent first, so the subset's more specific patterns win.
    private static let inheritedQuery: [String: String] = ["typescript": "javascript", "cpp": "c"]

    /// Load and compile the bundled `highlights.scm` for a grammar from the app's resource bundle,
    /// prepending its parent grammar's query when it has one.
    private static func highlightQuery(tsName: String, language: Language) -> Query? {
        guard let own = queryData(tsName) else { return nil }
        if let parent = inheritedQuery[tsName], let inherited = queryData(parent) {
            // A combined query fails to compile if the parent names nodes this grammar lacks — fall back
            // to the language's own patterns rather than losing highlighting entirely.
            if let combined = try? Query(language: language, data: inherited + own) { return combined }
        }
        do {
            return try Query(language: language, data: own)
        } catch {
            // A grammar we claim to support whose query won't compile is a bug signal, not a normal
            // outcome like an absent blob: the result is cached, so that language silently never
            // highlights for the rest of the run. Leave a trail so a bug report can name it.
            Log.warning("syntax: highlight query failed to compile for \(tsName): \(error)", category: .app)
            return nil
        }
    }

    private static func queryData(_ tsName: String) -> Data? {
        guard let url = queryURL(tsName: tsName) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Maps a tree-sitter highlight capture (e.g. `keyword.function`, `string`, `punctuation.bracket`)
    /// to a `SyntaxRole`, keyed on the capture's first component. Captures with no role (identifiers,
    /// properties, variables) return nil and render in the base foreground.
    static func role(forCapture nameComponents: [String]) -> SyntaxRole? {
        guard let head = nameComponents.first else { return nil }
        switch head {
        case "keyword", "conditional", "repeat", "include", "boolean", "preproc": return .keyword
        case "string", "character", "escape": return .string
        case "comment": return .comment
        case "number", "float", "constant": return .number
        case "type", "constructor", "attribute": return .type
        case "function", "method": return .function
        case "operator", "punctuation", "delimiter": return .punctuation
        case "text": return textRole(nameComponents)
        // Deliberately uncolored (base foreground): `variable`, `parameter`, `property`, `field`,
        // `label`, `spell`, `none` — identifiers read better plain, and `property` would make every
        // JS/TS member access loud.
        default: return nil
        }
    }

    /// Markdown's query is almost entirely `text.*`, so without these a `.md` file renders colorless.
    private static func textRole(_ nameComponents: [String]) -> SyntaxRole? {
        switch nameComponents.dropFirst().first {
        case "title": return .keyword  // headings
        case "literal": return .string  // inline and fenced code
        case "uri": return .string  // link targets
        case "reference": return .function  // link text / references
        default: return nil
        }
    }
}
