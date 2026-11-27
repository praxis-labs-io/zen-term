import AppKit

extension NSTextView {
    // AppKit defaults the caret and the selection to the macOS accent.
    func applyThemedEditing() {
        let chrome = Theme.current.chrome
        insertionPointColor = chrome.cursor.nsColor
        selectedTextAttributes = [.backgroundColor: chrome.tint(chrome.accent, alpha: ChromeTheme.badgeTint)]
    }
}
