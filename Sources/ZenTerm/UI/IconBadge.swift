import AppKit
import TerminalKit

// A symbol or brand mark on a rounded chip tinted by one chrome role.
final class IconBadge: NSView, ThemeReapplying {
    enum Size {
        case regular

        var side: CGFloat {
            switch self {
            case .regular: return 28
            }
        }

        var imageSide: CGFloat {
            switch self {
            case .regular: return 16
            }
        }

        var pointSize: CGFloat {
            switch self {
            case .regular: return ChromeMetrics.Icon.md
            }
        }
    }

    private let icon = NSImageView()
    private let role: (ChromeTheme) -> TerminalColor

    convenience init(
        symbol: String, accessibilityDescription: String?, size: Size, role: @escaping (ChromeTheme) -> TerminalColor
    ) {
        self.init(size: size, role: role)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
        icon.symbolConfiguration = .init(pointSize: size.pointSize, weight: .semibold)
    }

    convenience init(
        image: NSImage?, accessibilityDescription: String?, size: Size, role: @escaping (ChromeTheme) -> TerminalColor
    ) {
        self.init(size: size, role: role)
        icon.image = image
        icon.setAccessibilityLabel(accessibilityDescription)
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: size.imageSide),
            icon.heightAnchor.constraint(equalToConstant: size.imageSide),
        ])
    }

    private init(size: Size, role: @escaping (ChromeTheme) -> TerminalColor) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.side),
            heightAnchor.constraint(equalToConstant: size.side),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        let role = role(chrome)
        layer?.backgroundColor = chrome.tint(role, alpha: ChromeTheme.badgeTint).cgColor
        icon.contentTintColor = role.nsColor
    }

    var fillForTesting: CGColor? { layer?.backgroundColor }
    var iconTintForTesting: NSColor? { icon.contentTintColor }
    var iconImageForTesting: NSImage? { icon.image }
    var iconFrameForTesting: NSRect { icon.frame }
}
