import Foundation

/// Builds the prefilled GitHub issue for in-app "Report an Issue": a Markdown body from the user's
/// title and what-happened text plus a `SystemReport` environment block, and the new-issue URL that
/// carries them. Pure and Foundation-only, so the composer's submit path is unit-testable without a
/// browser.
struct IssueReport {
    let title: String
    let whatHappened: String
    let report: SystemReport

    /// Cap on the *pre-encoded* body. GitHub's prefill rides in the URL, which browsers cut around
    /// 8 KB; 6 KB leaves headroom for the title and percent-encoding. Only the user's text is trimmed
    /// to fit, so the environment and the diagnostics instruction always survive.
    static let maxBodyBytes = 6 * 1024

    /// The diagnostics instruction: the app has no backend, so the zip can't be uploaded from here.
    private static let diagnosticsNote = """
        Attached separately. In ZenTerm, run Export Diagnostics, then drag the .zip onto this issue. \
        The app can't upload files for you.
        """

    private static let truncationNotice = "\n\n_(truncated, paste the rest into the issue)_"

    /// The rendered Markdown body, with the user's text trimmed only if the whole would exceed the cap.
    var body: String {
        let full = Self.render(whatHappened: whatHappened, report: report)
        guard full.utf8.count > Self.maxBodyBytes else { return full }

        // Over budget: shrink only the user's text. The fixed parts (headers, environment, the
        // diagnostics note) render the same with an empty what-happened, so their size is the
        // overhead the user's text plus the notice must fit under.
        let overhead =
            Self.render(whatHappened: "", report: report).utf8.count
            + Self.truncationNotice.utf8.count
        let room = max(0, Self.maxBodyBytes - overhead)
        let trimmed = Self.clip(whatHappened, toUTF8Bytes: room)
        return Self.render(whatHappened: trimmed + Self.truncationNotice, report: report)
    }

    /// The prefilled new-issue URL, title and body baked in.
    var url: URL {
        SupportLinks.newIssueURL(title: title, body: body)
    }

    private static func render(whatHappened: String, report: SystemReport) -> String {
        """
        ### What happened
        \(whatHappened)

        ### Environment
        \(report.plainText)

        ### Diagnostics
        \(diagnosticsNote)
        """
    }

    /// Trim `text` to at most `limit` UTF-8 bytes without splitting a character (iterating by
    /// grapheme keeps an emoji or composed character whole).
    private static func clip(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        return result
    }
}
