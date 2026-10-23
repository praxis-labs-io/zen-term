import Foundation

/// Strips `THIRD-PARTY-NOTICES.md` markup for the plain-text window. License bodies stay verbatim, as a legal obligation.
enum Acknowledgements {
    static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                lines.append(line)
                continue
            }
            lines.append(stripPairedBold(strippedHeading(line) ?? line))
        }
        return lines.joined(separator: "\n")
    }

    /// Requires the space after the hashes, so a `#define` in a prose-quoted license is left alone.
    private static func strippedHeading(_ line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let afterHashes = line.index(line.startIndex, offsetBy: hashes)
        guard afterHashes < line.endIndex, line[afterHashes] == " " else { return nil }
        return String(line[line.index(after: afterHashes)...])
    }

    private static func stripPairedBold(_ line: String) -> String {
        guard line.contains("**") else { return line }
        var result = ""
        var rest = Substring(line)
        while let open = rest.range(of: "**"),
            let close = rest.range(of: "**", range: open.upperBound..<rest.endIndex)
        {
            result += rest[..<open.lowerBound]
            result += rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }
}
