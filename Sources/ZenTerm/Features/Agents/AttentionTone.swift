import AppKit

// One mapping for the whole chrome: surfaces differ in which states they show, never in the hue.
enum AttentionTone {
    case waiting, working, idle

    init(wait: AttentionStore.AgentWait?, working: Bool) {
        self = wait != nil ? .waiting : working ? .working : .idle
    }

    var ink: NSColor {
        let chrome = Theme.current.chrome
        switch self {
        case .waiting: return chrome.attention.nsColor
        case .working: return chrome.accent.nsColor
        case .idle: return chrome.ink(.muted)
        }
    }
}
