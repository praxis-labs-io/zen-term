import AppKit

enum FieldChrome {
    static func apply(to view: NSView, isFocused: Bool) {
        let chrome = Theme.current.chrome
        view.layer?.backgroundColor = chrome.fill(.rest).cgColor
        view.layer?.borderColor = (isFocused ? chrome.focusRing : chrome.fill(alpha: ChromeTheme.border)).cgColor
        view.layer?.borderWidth = ChromeMetrics.Border.width
    }
}
