import AppKit

enum StatusTokens {
    static let font = NSFont.systemFont(ofSize: 11)
    static let groupGap: CGFloat = 4

    static func joined(_ groups: [NSAttributedString]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for group in groups where group.length > 0 {
            if out.length > 0 {
                var attributes = out.attributes(at: out.length - 1, effectiveRange: nil)
                attributes[.kern] = groupGap
                out.append(NSAttributedString(string: " ", attributes: attributes))
            }
            out.append(group)
        }
        return out
    }
}
