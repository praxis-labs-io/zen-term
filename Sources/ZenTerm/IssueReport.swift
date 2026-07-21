import Foundation

/// Builds the prefilled GitHub issue for in-app "Report an Issue": a Markdown body from the user's
/// title and what-happened text plus a `SystemReport` environment block, and the new-issue URL that
/// carries them. Pure and Foundation-only, so the composer's submit path is unit-testable without a
/// browser.
struct IssueReport {
    let title: String
    let whatHappened: String
    let report: SystemReport

    /// Cap on the whole prefilled URL, measured after percent-encoding. GitHub's prefill rides in the
    /// URL, which browsers and servers cut around 8 KB; staying under keeps the issue from arriving
    /// truncated by the browser instead of by us. Capping the encoded URL (not the raw body) accounts
    /// for percent-encoding, which can triple the length of non-ASCII text. Only the user's text is
    /// trimmed to fit, so the environment and the diagnostics instruction always survive.
    static let maxURLBytes = 8000

    /// The diagnostics instruction: the app has no backend, so the zip can't be uploaded from here.
    private static let diagnosticsNote = """
        Attached separately. In ZenTerm, run Export Diagnostics, then drag the .zip onto this issue. \
        The app can't upload files for you.
        """

    private static let truncationNotice = "\n\n_(truncated, paste the rest into the issue)_"

    /// The rendered Markdown body, with the user's text trimmed only if the prefilled URL would
    /// exceed the cap.
    var body: String {
        let full = Self.render(whatHappened: whatHappened, report: report)
        guard urlBytes(for: full) > Self.maxURLBytes else { return full }

        // Over budget: binary-search the largest grapheme prefix of the user's text whose encoded URL
        // still fits, cutting on grapheme boundaries so a character (an emoji, a composed glyph) is
        // never split. Measuring the real URL is why this can't overshoot on non-ASCII input.
        let graphemes = Array(whatHappened)
        var low = 0
        var high = graphemes.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(graphemes[0..<mid]) + Self.truncationNotice
            if urlBytes(for: Self.render(whatHappened: candidate, report: report)) <= Self.maxURLBytes {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return Self.render(whatHappened: String(graphemes[0..<low]) + Self.truncationNotice, report: report)
    }

    /// The prefilled new-issue URL, title and body baked in.
    var url: URL {
        SupportLinks.newIssueURL(title: title, body: body)
    }

    private func urlBytes(for body: String) -> Int {
        SupportLinks.newIssueURL(title: title, body: body).absoluteString.utf8.count
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
}
