import Foundation

// The `<zen>` wrapper that tells an agent a paste came from another pane, not from its user.
enum ZenEnvelope {
    static func wrap(_ text: String, from sender: Int, named name: String?) -> String {
        let from = name.map { "\(sender) \(escaped($0))" } ?? "\(sender)"
        return "<zen from=\"\(from)\" reply=\"zen pane send --pane \(sender) --enter\">\(text)</zen>"
    }

    // Text carrying a tag of its own could close the wrapper early and pass the rest off as the user's words.
    static func carriesTag(_ text: String) -> Bool {
        text.range(of: "<zen", options: .caseInsensitive) != nil
            || text.range(of: "</zen", options: .caseInsensitive) != nil
    }

    static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
