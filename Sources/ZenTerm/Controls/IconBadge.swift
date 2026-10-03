import AppKit
import TerminalKit

// A symbol on a rounded chip tinted by one chrome role, as a toast leads with.
final class IconBadge: NSView {
    enum Size {
        case regular

        var side: CGFloat {
            switch self {
            case .regular: return 28
            }
        }

        var pointSize: CGFloat {
            switch self {
            case .regular: return 13
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .regular: return 7
            }
        }
    }

    private let icon = NSImageView()
    private let role: (ChromeTheme) -> TerminalColor

    init(symbol: String, accessibilityDescription: String?, size: Size, role: @escaping (ChromeTheme) -> TerminalColor)
    {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size.cornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
        icon.symbolConfiguration = .init(pointSize: size.pointSize, weight: .semibold)
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
}
