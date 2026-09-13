import Foundation

enum SupportLinks {
    static let issuesOwner = "praxis-labs-io"
    static let issuesRepo = "zen-term"

    /// Encodes "+" as %2B: GitHub form-decodes the query, where a bare "+" is a space.
    static func newIssueURL(title: String, body: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(issuesOwner)/\(issuesRepo)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
