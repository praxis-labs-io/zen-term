import AppKit

final class TooltipHost {
    var label: String
    var style: ChromeTooltip.Style
    private let shortcut: (() -> String?)?

    init(label: String, shortcut: (() -> String?)? = nil, style: ChromeTooltip.Style = .line) {
        self.label = label
        self.style = style
        self.shortcut = shortcut
    }

    func show(from source: NSView) {
        TooltipPresenter.shared.scheduleShow(for: source, label: label, shortcut: shortcut?(), style: style)
    }

    func hide(from source: NSView) {
        TooltipPresenter.shared.hide(for: source)
    }

    var shortcutForTesting: String? { shortcut?() }
}
