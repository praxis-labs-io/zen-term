import AppKit

final class TooltipHost {
    let label: String
    private let shortcut: (() -> String?)?

    init(label: String, shortcut: (() -> String?)? = nil) {
        self.label = label
        self.shortcut = shortcut
    }

    func show(from source: NSView) {
        TooltipPresenter.shared.scheduleShow(for: source, label: label, shortcut: shortcut?())
    }

    func hide(from source: NSView) {
        TooltipPresenter.shared.hide(for: source)
    }

    var shortcutForTesting: String? { shortcut?() }
}
