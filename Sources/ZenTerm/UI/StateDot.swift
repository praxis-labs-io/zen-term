import AppKit

final class StateDot: NSView, ThemeReapplying {
    enum State: CaseIterable {
        case blocked, done, live

        var accessibilityValue: String {
            switch self {
            case .blocked: return "Agent waiting for approval"
            case .done: return "Agent finished its turn"
            case .live: return "Running"
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
        case .live: return chrome.accent.nsColor
        }
    }
}
