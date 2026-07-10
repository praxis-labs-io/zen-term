import AppKit

/// The Keybinds settings section: remap the built-in actions. Task 8 fleshes out the editor;
/// this scaffold gives the shell a registered section so the card opens with a working nav.
final class SettingsKeybindsSection: SettingsSection {
    var navTitle: String { "Keybinds" }
    var onExitToNav: (() -> Void)?

    func makeDetailView() -> NSView {
        let label = NSTextField(labelWithString: "Keybinds")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func detailStops() -> [NSView] { [] }
}
