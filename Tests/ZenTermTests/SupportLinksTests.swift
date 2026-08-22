import XCTest

@testable import ZenTerm

final class SupportLinksTests: XCTestCase {
    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    func test_newIssueURL_pointsAtTheReleasesRepoNewIssue() {
        let url = SupportLinks.newIssueURL(title: "hi", body: "there")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "github.com")
        XCTAssertEqual(components?.path, "/praxis-labs-io/zen-term/issues/new")
        XCTAssertEqual(query(url, "title"), "hi")
        XCTAssertEqual(query(url, "body"), "there")
    }

    func test_newIssueURL_encodesSpecialCharactersReversibly() {
        // A title/body with the characters a real report carries: spaces, reserved URL chars, a
        // newline, and an emoji. They must round-trip so the browser shows exactly what was typed.
        let title = "crash in #5 & pane <2>"
        let body = "step 1\nstep 2 🎉 done?value=x"
        let url = SupportLinks.newIssueURL(title: title, body: body)

        XCTAssertEqual(query(url, "title"), title)
        XCTAssertEqual(query(url, "body"), body)
        XCTAssertFalse(url.absoluteString.contains(" "), "spaces must be percent-encoded in the URL")
    }

    func test_newIssueURL_encodesPlusSoGitHubDoesNotFormDecodeItToSpace() {
        // GitHub form-decodes the query, where a bare "+" means a space, so "C++" would arrive as
        // "C  ". The "+" must be percent-encoded to survive.
        let url = SupportLinks.newIssueURL(title: "1+1=2", body: "C++ pane crash")
        XCTAssertFalse(url.absoluteString.contains("+"), "a literal + must be encoded, not left bare")
        XCTAssertTrue(url.absoluteString.contains("%2B"), "+ is encoded as %2B")
    }
}
