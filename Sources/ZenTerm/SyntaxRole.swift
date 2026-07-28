import AppKit

/// A token's syntax-highlighting role, resolved to a color from `Theme.current` at render time.
///
/// The role is what gets stored on a `TokenSpan` in the row model — never a baked `NSColor`. This
/// is the single place role→color lives, so a live theme swap (`reloadData` → `configure`) recolors
/// every visible span by re-resolving against the new theme; a color baked into the model would
/// survive the swap and wash out on the next theme (ZEN-27).
enum SyntaxRole: Equatable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case punctuation

    func color(_ chrome: ChromeTheme) -> NSColor {
        switch self {
        case .keyword: return chrome.synKeyword.nsColor
        case .string: return chrome.synString.nsColor
        case .comment: return chrome.synComment.nsColor
        case .number: return chrome.synNumber.nsColor
        case .type: return chrome.synType.nsColor
        case .function: return chrome.synFunction.nsColor
        case .punctuation: return chrome.synPunctuation.nsColor
        }
    }
}
