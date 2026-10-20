import AppKit

/// TextKit 1, because TextKit 2 has no hook for the color of a selection that has lost focus.
class ChromeTextView: NSTextView {
    convenience init() {
        self.init(usingTextLayoutManager: false)
        textContainer?.replaceLayoutManager(SelectionLayoutManager())
    }

    static func makeFieldEditor() -> ChromeTextView {
        let editor = ChromeTextView()
        editor.isFieldEditor = true
        return editor
    }

    override func becomeFirstResponder() -> Bool {
        let gained = super.becomeFirstResponder()
        if gained { applyThemedEditing() }
        return gained
    }
}

// AppKit has no API for the unfocused selection color, and super fills with the current color, not `color`.
private final class SelectionLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor
    ) {
        var fill = color
        if isUnfocusedSelection(charRange, color: color) {
            fill = Theme.current.chrome.fill(.active)
            fill.setFill()
        }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: fill)
    }

    private func isUnfocusedSelection(_ charRange: NSRange, color: NSColor) -> Bool {
        guard let view = firstTextView, color != view.selectedTextAttributes[.backgroundColor] as? NSColor else {
            return false
        }
        return view.selectedRanges.contains { NSIntersectionRange($0.rangeValue, charRange).length > 0 }
    }
}
