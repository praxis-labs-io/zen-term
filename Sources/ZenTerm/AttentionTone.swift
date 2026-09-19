import AppKit

/// The chrome's one state-to-color mapping. Surfaces differ in which states they show, never in the hue they use.
enum AttentionTone {
    case waiting, working, done, failed, idle

    init(_ attention: SurfaceAttention, failed: Bool = false) {
        switch attention {
        case .waiting: self = .waiting
        case .working: self = .working
        case .completed: self = failed ? .failed : .done
        case .idle: self = .idle
        }
    }

    var ink: NSColor {
        let chrome = Theme.current.chrome
        switch self {
        case .waiting: return chrome.attention.nsColor
        case .working: return chrome.accent.nsColor
        case .done: return chrome.positive.nsColor
        case .failed: return chrome.destructive.nsColor
        case .idle: return chrome.ink(.muted)
        }
    }
}
