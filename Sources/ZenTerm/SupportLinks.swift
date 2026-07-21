import Foundation

/// Where in-app "Report an Issue" sends people. This repo is private, so bugs are filed against the
/// public `zen-term/zen-term-releases` tracker, where the downloads live.
enum SupportLinks {
    static let issuesOwner = "zen-term"
    static let issuesRepo = "zen-term-releases"

    /// GitHub's prefilled "new issue" URL with the title and body baked in. Built with
    /// `URLComponents`/`URLQueryItem` so a title or body carrying spaces, `#`, `&`, emoji, or
    /// newlines is percent-encoded correctly (hand-rolled escaping gets the reserved characters
    /// wrong). All the components are statically valid, so `.url` is never nil in practice; the
    /// fallback keeps the function total without a force-unwrap.
    static func newIssueURL(title: String, body: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(issuesOwner)/\(issuesRepo)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
