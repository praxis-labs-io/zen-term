import AppKit

// The short vertical rule between groups of icon buttons, as opposed to `Divider`'s full-length hairline.
final class ToolbarDivider: NSView, ThemeReapplying {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ChromeMetrics.Border.width),
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Spacing.s12),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.divider).cgColor
    }
}
