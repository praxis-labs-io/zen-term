import Foundation

struct IssueReport {
    let title: String
    let whatHappened: String
    let report: SystemReport

    // Browsers and servers cut URLs around 8 KB; measured after percent-encoding, which can triple non-ASCII.
    static let maxURLBytes = 8000

    private static let diagnosticsNote = """
        Attached separately. In ZenTerm, run Export Diagnostics, then drag the .zip onto this issue. \
        The app can't upload files for you.
        """

    private static let truncationNotice = "\n\n_(truncated, paste the rest into the issue)_"

    var body: String {
        let full = Self.render(whatHappened: whatHappened, report: report)
        guard urlBytes(for: full) > Self.maxURLBytes else { return full }

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
