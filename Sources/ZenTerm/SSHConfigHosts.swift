import Darwin
import Foundation

// Lists the literal `Host` aliases of an ssh config, best-effort: an include it cannot read is skipped.
enum SSHConfigHosts {
    struct Listing: Equatable {
        let aliases: [String]
        let isUnreadable: Bool
    }

    #if DEBUG
        static var userConfigOverrideForTesting: URL?
    #endif

    static var userConfig: URL {
        #if DEBUG
            if let userConfigOverrideForTesting { return userConfigOverrideForTesting }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config")
    }

    private static let maxIncludeDepth = 16  // OpenSSH's own `Include` limit

    static func listing(of file: URL) -> Listing {
        var aliases: [String] = []
        var visited: Set<String> = []
        let wasRead = collect(
            file, includeBase: file.deletingLastPathComponent(), depth: 0, visited: &visited, into: &aliases)
        return Listing(aliases: aliases, isUnreadable: !wasRead && FileManager.default.fileExists(atPath: file.path))
    }

    @discardableResult
    private static func collect(
        _ file: URL, includeBase: URL, depth: Int, visited: inout Set<String>, into aliases: inout [String]
    ) -> Bool {
        guard depth <= maxIncludeDepth,
            visited.insert(file.resolvingSymlinksInPath().standardizedFileURL.path).inserted,
            let text = try? String(contentsOf: file, encoding: .utf8)
        else { return false }
        var inMatch = false
        for line in text.components(separatedBy: .newlines) {
            guard let (keyword, args) = directive(line) else { continue }
            switch keyword {
            case "host":
                inMatch = false
                for alias in args where isLiteral(alias) && !aliases.contains(alias) { aliases.append(alias) }
            case "match":
                inMatch = true
            case "include" where !inMatch:
                for path in args.flatMap({ includedPaths($0, base: includeBase) }) {
                    collect(
                        URL(fileURLWithPath: path), includeBase: includeBase, depth: depth + 1, visited: &visited,
                        into: &aliases)
                }
            default:
                continue
            }
        }
        return true
    }

    private static func directive(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let split = trimmed.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else {
            return (trimmed.lowercased(), [])
        }
        var rest = trimmed[split...].drop(while: \.isWhitespace)
        if rest.first == "=" { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        return (trimmed[..<split].lowercased(), arguments(rest))
    }

    private static func arguments(_ text: Substring) -> [String] {
        var args: [String] = []
        var token = ""
        var isQuoted = false
        for char in text {
            if char == "\"" {
                isQuoted.toggle()
            } else if char.isWhitespace && !isQuoted {
                if !token.isEmpty { args.append(token) }
                token = ""
            } else if char == "#" && token.isEmpty && !isQuoted {
                return args
            } else {
                token.append(char)
            }
        }
        if !token.isEmpty { args.append(token) }
        return args
    }

    private static func isLiteral(_ alias: String) -> Bool {
        !alias.hasPrefix("!") && !alias.contains("*") && !alias.contains("?")
    }

    private static func includedPaths(_ pattern: String, base: URL) -> [String] {
        let expanded = PathDisplay.expandingHome(pattern)
        let absolute = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
        guard absolute.contains(where: { "*?[".contains($0) }) else { return [absolute] }
        return globMatches(absolute)
    }

    private static func globMatches(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }
    }
}
