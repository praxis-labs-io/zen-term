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
        // URLQueryItem leaves a literal "+" unescaped (it's RFC-3986-legal), but GitHub form-decodes
        // the query, where "+" means a space — so "C++" would arrive as "C  ". Encode it to %2B; the
        // space is already %20, so nothing else is affected.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
