import AppKit

extension NSTextField {
    // The field editor is shared per window, so a theme change has to reach the one this field is editing with.
    func applyThemedEditor() {
        (currentEditor() as? NSTextView)?.applyThemedEditing()
    }
}
