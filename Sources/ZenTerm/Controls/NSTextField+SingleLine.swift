import AppKit

extension NSTextField {
    func makeSingleLine() {
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
    }
}
