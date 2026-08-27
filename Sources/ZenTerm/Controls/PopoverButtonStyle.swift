import AppKit

/// The button half of a popover control: the fill and border that say focused, or open.
///
/// Shared by `Dropdown` and `CheckboxDropdown`, which sit next to each other in Settings, so a
/// copy that drifted would read as one picker lighting up differently from the one below it.
enum PopoverButtonStyle {
    private static var restFill: NSColor { Theme.current.chrome.fill(.rest) }
    private static var focusFill: NSColor { Theme.current.chrome.selectionFill }

    /// The resting fill, for a control painting itself before it has focus or an open list.
    static func applyRestFill(to view: NSView) {
        view.layer?.backgroundColor = restFill.cgColor
    }

    static func apply(to view: NSView, isFocused: Bool, isOpen: Bool) {
        let chrome = Theme.current.chrome
        let lit = isFocused || isOpen
        view.layer?.backgroundColor = (lit ? focusFill : restFill).cgColor
        view.layer?.borderColor = (lit ? chrome.accent.nsColor : chrome.fill(alpha: ChromeTheme.border)).cgColor
        view.layer?.borderWidth = lit ? 1.5 : 1
    }
}
