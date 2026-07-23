import AppKit

/// The `+n −m` add/remove badge, rendered the same way wherever it appears: the tree's section headers
/// and the viewer footer. Additions read in the theme's positive role, removals in destructive (ZEN-27);
/// a zero side is omitted, and an all-zero change yields an empty string (a rename or binary shows nothing).
enum DiffStatText {
    static func attributed(added: Int, removed: Int, fontSize: CGFloat = 11) -> NSAttributedString {
        let chrome = Theme.current.chrome
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let text = NSMutableAttributedString()
        if added > 0 {
            text.append(
                NSAttributedString(
                    string: "+\(added)", attributes: [.foregroundColor: chrome.positive.nsColor, .font: font]))
        }
        if removed > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            text.append(
                NSAttributedString(
                    string: "−\(removed)", attributes: [.foregroundColor: chrome.destructive.nsColor, .font: font]))
        }
        return text
    }
}
