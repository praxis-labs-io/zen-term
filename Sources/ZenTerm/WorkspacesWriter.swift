import Foundation

enum WorkspacesWriter {
    enum WriteError: Error, LocalizedError {
        case titleExists(String)

        var errorDescription: String? {
            switch self {
            case .titleExists(let title): return "A workspace named “\(title)” already exists."
            }
        }
    }

    /// Matches the alignment in `docs/config/workspaces`.
    private static let keyColumnWidth = 6

    /// `carry` keeps its authored order; env keys sort for stable output.
    static func serialize(_ ws: Workspace) -> String {
        var lines = ["[\(ws.title)]"]
        func add(_ key: String, _ rendered: String) {
            let paddedKey = key.padding(toLength: max(key.count, keyColumnWidth), withPad: " ", startingAt: 0)
            lines.append("\(paddedKey) = \(rendered)")
        }
        add("path", quoted(PathDisplay.abbreviatingHome(ws.path.path)))
        if let main = ws.main { add("main", quoted(main)) }
        if let right = ws.right { add("right", quoted(right)) }
        if let bottom = ws.bottom { add("bottom", quoted(bottom)) }
        if ws.focus != .main { add("focus", ws.focus.rawValue) }
        for entry in ws.carry { add("carry", quoted(entry)) }
        for key in ws.env.keys.sorted() {
            add("env", "\(key)=\(quoted(ws.env[key] ?? ""))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func append(_ ws: Workspace, configRoot: URL = ConfigLoader.defaultRoot) throws {
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let url = configRoot.appendingPathComponent("workspaces")
        let existing = try ConfigFileIO.readExistingOrEmpty(url)
        guard !WorkspacesParser.parse(existing).contains(where: { $0.title == ws.title }) else {
            throw WriteError.titleExists(ws.title)
        }
        let separator: String
        if existing.isEmpty {
            separator = ""
        } else if existing.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        try ConfigFileIO.writePreservingSymlink(existing + separator + serialize(ws), to: url)
    }

    /// Comments inside the edited section are not preserved. Appends when `originalTitle` is absent.
    static func update(_ ws: Workspace, originalTitle: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let url = configRoot.appendingPathComponent("workspaces")
        let existing = try ConfigFileIO.readExistingOrEmpty(url)
        if ws.title != originalTitle,
            WorkspacesParser.parse(existing).contains(where: { $0.title == ws.title })
        {
            throw WriteError.titleExists(ws.title)
        }
        var lines = existing.components(separatedBy: "\n")
        guard let span = locateSection(titled: originalTitle, in: lines) else {
            try append(ws, configRoot: configRoot)
            return
        }
        let body = Array(serialize(ws).components(separatedBy: "\n").dropLast())
        lines.replaceSubrange(span.start..<span.bodyEnd, with: body)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try ConfigFileIO.writePreservingSymlink(lines.joined(separator: "\n"), to: url)
    }

    static func remove(title: String, configRoot: URL = ConfigLoader.defaultRoot) throws {
        let url = configRoot.appendingPathComponent("workspaces")
        let existing = try ConfigFileIO.readExistingOrEmpty(url)
        var lines = existing.components(separatedBy: "\n")
        guard let span = locateSection(titled: title, in: lines) else { return }
        var end = span.bodyEnd
        while end < span.nextHeader, lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end += 1
        }
        lines.removeSubrange(span.start..<end)
        try ConfigFileIO.writePreservingSymlink(lines.joined(separator: "\n"), to: url)
    }

    /// Returns false when either title is missing, so a stale row is not reported as swapped.
    static func swap(
        _ title: String, with other: String, configRoot: URL = ConfigLoader.defaultRoot
    ) throws -> Bool {
        let url = configRoot.appendingPathComponent("workspaces")
        var lines = try ConfigFileIO.readExistingOrEmpty(url).components(separatedBy: "\n")
        guard let a = locateBlock(titled: title, in: lines),
            let b = locateBlock(titled: other, in: lines)
        else { return false }
        let (earlier, later) = a.start < b.start ? (a, b) : (b, a)
        let earlierBlock = Array(lines[earlier.start..<earlier.end])
        let laterBlock = Array(lines[later.start..<later.end])
        lines.replaceSubrange(later.start..<later.end, with: earlierBlock)
        lines.replaceSubrange(earlier.start..<earlier.end, with: laterBlock)
        try ConfigFileIO.writePreservingSymlink(lines.joined(separator: "\n"), to: url)
        return true
    }

    private static func locateBlock(titled title: String, in lines: [String]) -> (start: Int, end: Int)? {
        guard let span = locateSection(titled: title, in: lines) else { return nil }
        var start = span.start
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
            start -= 1
        }
        return (start, span.bodyEnd)
    }

    private static func locateSection(
        titled title: String, in lines: [String]
    ) -> (start: Int, bodyEnd: Int, nextHeader: Int)? {
        func headerTitle(_ line: String) -> String? {
            let stripped = ConfigText.stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard stripped.hasPrefix("["), stripped.hasSuffix("]") else { return nil }
            return String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let start = lines.lastIndex(where: { headerTitle($0) == title }) else { return nil }
        var nextHeader = lines.count
        var index = start + 1
        while index < lines.count {
            if headerTitle(lines[index]) != nil {
                nextHeader = index
                break
            }
            index += 1
        }
        var bodyEnd = nextHeader
        while bodyEnd > start + 1,
            ConfigText.stripComment(lines[bodyEnd - 1]).trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        {
            bodyEnd -= 1
        }
        return (start, bodyEnd, nextHeader)
    }

    /// Never escapes `"`: the format has none, and the form rejects the character.
    private static func quoted(_ value: String) -> String {
        let needsQuoting = value.contains("#") || value.contains(where: \.isWhitespace)
        return needsQuoting ? "\"\(value)\"" : value
    }

}
