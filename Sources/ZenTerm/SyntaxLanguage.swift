import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// Resolves a file path to a tree-sitter grammar + compiled highlight query (ZEN-239), and maps a
/// query capture name to one of ZEN-238's `SyntaxRole`s. Thin façade over `CodeEditLanguages`, which
/// bundles the grammars (incl. Swift) and their `highlights.scm` — so the engine never vendors a
/// `parser.c`. Keyed off `FileDiff.path`'s extension.
enum SyntaxLanguage {
    /// The grammar + highlight query for a path, or nil when the language isn't supported (or has no
    /// bundled query) — the caller renders that file plain.
    ///
    /// The grammar comes from `CodeEditLanguages` (the linked tree-sitter parser), but the highlight
    /// query is loaded from *our* resource bundle: `CodeEditLanguages`' own query loader builds its
    /// `Bundle.module` path wrong under terminal-native SwiftPM (a doubled `Resources/Resources`), and
    /// the app already avoids `Bundle.module` for exactly this class of bug (`ZenTermResources`).
    static func resolve(path: String) -> (language: Language, query: Query)? {
        let code = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path))
        guard code.id != .plainText, let language = code.language,
            let query = highlightQuery(tsName: code.tsName, language: language)
        else { return nil }
        return (language, query)
    }

    /// Load and compile the bundled `highlights.scm` for a grammar from the app's resource bundle.
    private static func highlightQuery(tsName: String, language: Language) -> Query? {
        guard
            let url = ZenTermResources.bundle.url(
                forResource: "highlights", withExtension: "scm",
                subdirectory: "SyntaxQueries/tree-sitter-\(tsName)"),
            let data = try? Data(contentsOf: url)
        else { return nil }
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
