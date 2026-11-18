import AppKit

final class Divider: NSView, ThemeReapplying {
    enum Orientation {
        case horizontal
        case vertical
    }

    init(_ orientation: Orientation = .horizontal) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let thickness = orientation == .horizontal ? heightAnchor : widthAnchor
        thickness.constraint(equalToConstant: ChromeMetrics.Border.width).isActive = true
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
    }
}
