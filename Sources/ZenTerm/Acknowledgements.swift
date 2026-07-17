import Foundation

/// Turns the shipped `THIRD-PARTY-NOTICES.md` into plain text for the Acknowledgements window, which
/// renders a flat string rather than Markdown. The notices file is Markdown because it is also a repo
/// doc and a top-level file in the app bundle that people read as text; the window is the one consumer
/// that wants the scaffolding gone.
///
/// The transform only removes markup this file's own prose uses, and it is built so it stays harmless
/// even on a license quoted as prose rather than fenced: it strips a `#` run only when it forms a real
/// ATX heading (hashes then a space), and `**` only as a matched pair. So a `#define` line or an
/// unpaired `** Copyright` banner passes through verbatim, and a fenced body is never touched at all.
/// License bodies are quoted verbatim and their exact wording and indentation are a legal obligation.
enum Acknowledgements {
    static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                // A fence delimiter itself is scaffolding; the body between delimiters is verbatim
                // license text and passes through below, indentation intact.
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

    /// A heading (`### FreeType`) without its `#`s and the one space after them, or nil if the line
    /// isn't an ATX heading. Requires the space so `#define`, a plausible line in a prose-quoted
    /// license, is left alone.
    private static func strippedHeading(_ line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let afterHashes = line.index(line.startIndex, offsetBy: hashes)
        guard afterHashes < line.endIndex, line[afterHashes] == " " else { return nil }
        return String(line[line.index(after: afterHashes)...])
    }

    /// Removes our bold markers (`**MIT**`) by unwrapping matched `**…**` pairs, leaving any unpaired
    /// `**` — a banner like `** Copyright …` in a prose-quoted license — in place.
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
