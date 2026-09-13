import AppKit

enum PopoverButtonStyle {
    private static var restFill: NSColor { Theme.current.chrome.fill(.rest) }
    private static var focusFill: NSColor { Theme.current.chrome.selectionFill }

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
