import AppKit

/// The shared hover-tooltip wiring for a control: holds the label + a live keybind resolver and
/// drives the one `TooltipPresenter`. `IconButton` and `TabBarView.Chip` each own one and delegate
/// their hover / click / window-exit hooks to it, instead of re-implementing the schedule + teardown
/// glue in two places (ZEN-137). The keybind is resolved at show time, so it tracks the live keymap.
final class TooltipHost {
    let label: String
    private let shortcut: (() -> String?)?

    init(label: String, shortcut: (() -> String?)? = nil) {
        self.label = label
        self.shortcut = shortcut
    }

    /// Arm the branded tooltip for `source` after the presenter's hover delay.
    func show(from source: NSView) {
        TooltipPresenter.shared.scheduleShow(for: source, label: label, shortcut: shortcut?())
    }

    /// Dismiss the tooltip if `source` owns it (a no-op otherwise).
    func hide(from source: NSView) {
        TooltipPresenter.shared.hide(for: source)
    }

    /// Test hook: the resolved keybind glyph (ZEN-42 / ZEN-110).
    var shortcutForTesting: String? { shortcut?() }
}
