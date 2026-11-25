import AppKit

final class StateDot: NSView, ThemeReapplying {
    enum State: CaseIterable {
        case blocked, done, idle, live, online, working

        var accessibilityValue: String {
            switch self {
            case .blocked: return "Agent waiting for approval"
            case .done: return "Agent finished its turn"
            case .idle: return "Agent idle"
            case .live: return "Running"
            case .online: return "Host online"
            case .working: return "Agent working"
            }
        }
    }

    static let diameter: CGFloat = 6

    var state: State? {
        didSet {
            guard state != oldValue else { return }
            reapplyTheme()
        }
    }

    init(_ state: State? = nil) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.diameter)
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }

    var colorForTesting: CGColor? { layer?.backgroundColor }

    func reapplyTheme() {
        layer?.backgroundColor = state.map(Self.color)?.cgColor
    }

    private static func color(_ state: State) -> NSColor {
        let chrome = Theme.current.chrome
        switch state {
        case .blocked: return chrome.blocked.nsColor
        case .done: return chrome.done.nsColor
        case .idle: return chrome.ink(.muted)
        case .live: return chrome.accent.nsColor
        case .online: return chrome.positive.nsColor
        case .working: return chrome.working.nsColor
        }
    }
}
