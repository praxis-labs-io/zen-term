import AppLog
import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// Resolves a file path to a tree-sitter grammar + compiled highlight query (ZEN-239), and maps a
/// query capture name to one of ZEN-238's `SyntaxRole`s. Thin façade over `CodeEditLanguages`, which
/// bundles the grammars (incl. Swift) and their `highlights.scm` — so the engine never vendors a
/// `parser.c`. Keyed off `FileDiff.path`'s extension (or well-known filename), with the blob's own
/// shebang or modeline breaking the tie for an extensionless file (ZEN-329).
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
    /// bundled query) — the caller renders that file plain. `content` is the blob's text, when the
    /// caller has it: it feeds shebang and modeline detection for a path the extension table can't
    /// answer (ZEN-329). Never sniffed beyond those two signals — an ambiguous key=value config maps
    /// to no grammar correctly, so it deliberately stays plain.
    ///
    /// The grammar comes from `CodeEditLanguages` (the linked tree-sitter parser), but the highlight
    /// query is loaded from *our* resource bundle: `CodeEditLanguages`' own query loader builds its
    /// `Bundle.module` path wrong under terminal-native SwiftPM (a doubled `Resources/Resources`), and
    /// the app already avoids `Bundle.module` for exactly this class of bug (`ZenTermResources`).
    static func resolve(path: String, content: String? = nil) -> (language: Language, query: Query)? {
        let (prefix, suffix) = detectionBuffers(content)
        var code = CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: path), prefixBuffer: prefix, suffixBuffer: suffix)
        if code.id == .plainText, let prefix, let aliased = aliasedInterpreterLanguage(prefix) {
            code = aliased
        }
        guard code.id != .plainText, let language = code.language else { return nil }
        return resolvedQuery(tsName: code.tsName, language: language)
    }

    /// Whether the path alone can't answer but the blob's content might: no extension, so a shebang
    /// or modeline is the only signal. These files paint plain immediately and enrich if detection
    /// lands — never the withhold-paint path, which would hold every extensionless config file's
    /// first paint to the safety cap. A path with an *unknown* extension is not detectable: the
    /// extension is a real answer, and it says plain.
    static func isContentDetectable(path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.isEmpty && !isSupported(path: path)
    }

    /// The first and last few lines of the blob, sized for the two content signals: a shebang is
    /// line 1, and editors keep modelines within the first or last handful of lines.
    private static let detectionLineCount = 5

    private static func detectionBuffers(_ content: String?) -> (prefix: String?, suffix: String?) {
        guard let content else { return (nil, nil) }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let prefix = lines.prefix(detectionLineCount).joined(separator: "\n")
        let suffix =
            lines.count > detectionLineCount
            ? lines.suffix(detectionLineCount).joined(separator: "\n") : nil
        return (prefix, suffix)
    }

    /// Interpreters `CodeEditLanguages`' shebang tables don't list, mapped to the grammar that parses
    /// them: zsh is close enough to bash that its grammar highlights a zsh script correctly. The
    /// dependency's tables aren't ours to edit, so the shim lives here.
    private static let interpreterAliases: [String: CodeLanguage] = ["zsh": .bash]

    /// Resolve `#!/bin/zsh` and `#!/usr/bin/env zsh` shapes the package's own matcher misses. Mirrors
    /// its parse: the interpreter is the first token's last path component, or after `env`, the next
    /// token that isn't an option (`-S`) or an assignment (`FOO=bar`).
    private static func aliasedInterpreterLanguage(_ prefix: String) -> CodeLanguage? {
        guard let firstLine = prefix.split(separator: "\n").first, firstLine.hasPrefix("#!") else { return nil }
        let tokens = firstLine.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard var interpreter = tokens.first?.split(separator: "/").last else { return nil }
        if interpreter == "env" {
            guard
                let next = tokens.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.contains("=") }),
                let name = next.split(separator: "/").last
            else { return nil }
            interpreter = name
        }
        return interpreterAliases[interpreter.lowercased()]
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
        // Must agree with `resolve` on all three conditions, grammar included: a language whose id is
        // known but whose grammar pointer is nil would otherwise be called supported, and the viewer
        // would withhold the first paint for the full safety cap waiting on a highlight that can never
        // arrive. Cheap — `language` is a pointer switch, no I/O.
        return code.id != .plainText && code.language != nil && queryURL(tsName: code.tsName) != nil
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
