import XCTest

@testable import ZenTerm

final class IssueReportTests: XCTestCase {
    private let report = SystemReport(
        appVersion: "0.3.0", build: "1234", osVersion: "15.5 (24F74)", architecture: "arm64")

    func test_body_carriesUserTextAndEnvironmentAndDiagnostics() {
        let issue = IssueReport(
            title: "Crash on split", whatHappened: "It closed when I hit cmd-d", report: report)
        let body = issue.body

        XCTAssertTrue(body.contains("### What happened"))
        XCTAssertTrue(body.contains("It closed when I hit cmd-d"))
        XCTAssertTrue(body.contains("### Environment"))
        XCTAssertTrue(body.contains(report.plainText), "environment is the SystemReport block verbatim")
        XCTAssertTrue(body.contains("### Diagnostics"))
        XCTAssertTrue(body.contains("Export Diagnostics"), "the diagnostics instruction is present")
    }

    func test_body_ownCopyHasNoEmDash() {
        // Brand voice: the body's own fixed copy (the diagnostics instruction, any truncation notice)
        // carries no em-dash. User text isn't governed, so this uses none.
        let issue = IssueReport(title: "t", whatHappened: "w", report: report)
        XCTAssertFalse(issue.body.contains("—"), "no em-dash in the issue body's own copy")
    }

    func test_url_isThePrefilledNewIssueURLCarryingTitleAndBody() {
        let issue = IssueReport(title: "My title", whatHappened: "details", report: report)
        let components = URLComponents(url: issue.url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.path, "/zen-term/zen-term-releases/issues/new")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "title" }?.value, "My title")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "body" }?.value, issue.body)
    }

    func test_body_overBudget_capsTheUrlAndKeepsTheRest() {
        let huge = String(repeating: "A", count: 20_000)  // far past the URL cap
        let issue = IssueReport(title: "big", whatHappened: huge, report: report)
        let body = issue.body

        XCTAssertLessThanOrEqual(
            issue.url.absoluteString.utf8.count, IssueReport.maxURLBytes, "the prefilled URL is capped")
        XCTAssertTrue(body.contains("### Environment"))
        XCTAssertTrue(body.contains(report.plainText), "environment survives truncation")
        XCTAssertTrue(body.contains("### Diagnostics"), "diagnostics instruction survives truncation")
        XCTAssertTrue(body.contains("truncated"), "a truncation notice is added")
        XCTAssertTrue(body.contains("AAAA"), "some of the user text is kept")
    }

    func test_body_overBudget_withNonASCII_stillCapsTheEncodedURL() {
        // Percent-encoding triples each of these 3-byte characters, so a raw-byte cap would let the
        // encoded URL overflow. The cap measures the real URL, so it holds regardless.
        let huge = String(repeating: "行", count: 8_000)
        let issue = IssueReport(title: "big", whatHappened: huge, report: report)

        XCTAssertLessThanOrEqual(issue.url.absoluteString.utf8.count, IssueReport.maxURLBytes)
        XCTAssertTrue(issue.body.contains("行"), "some of the user text is kept")
        XCTAssertTrue(issue.body.contains(report.plainText), "environment survives")
    }

    func test_body_underBudget_isNotTruncated() {
        let issue = IssueReport(title: "t", whatHappened: "short and sweet", report: report)
        XCTAssertFalse(issue.body.contains("truncated"))
        XCTAssertTrue(issue.body.contains("short and sweet"))
    }
}
