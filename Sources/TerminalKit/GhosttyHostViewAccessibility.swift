import AppKit
import GhosttyKit

// Reads the screen synchronously on main: libghostty calls must run there, and it is a cached memory copy.
extension GhosttyHostView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityHelp() -> String? { "Terminal content area" }

    override func accessibilityValue() -> Any? { screenContents() }

    override func accessibilitySelectedTextRange() -> NSRange { selectedRange() }

    override func accessibilitySelectedText() -> String? {
        guard let surfacePtr else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard let ptr = text.text else { return nil }
        let selection = String(cString: ptr)
        return selection.isEmpty ? nil : selection
    }

    override func accessibilityNumberOfCharacters() -> Int {
        (screenContents() as NSString).length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: (screenContents() as NSString).length)
    }

    override func accessibilityLine(for index: Int) -> Int {
        let contents = screenContents() as NSString
        let clamped = min(max(index, 0), contents.length)
        let prefix = contents.substring(to: clamped)
        return prefix.unicodeScalars.lazy.filter(CharacterSet.newlines.contains).count
    }

    // Clients probe stale ranges up to NSNotFound, where `NSMaxRange` would overflow past the bounds check.
    override func accessibilityString(for range: NSRange) -> String? {
        let contents = screenContents() as NSString
        guard range.location >= 0, range.length >= 0,
            range.location <= contents.length,
            range.length <= contents.length - range.location
        else { return nil }
        return contents.substring(with: range)
    }

    // ghostty returns a +1 CTFont, released here after the attribute retains it.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let plain = accessibilityString(for: range) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let surfacePtr, let fontRaw = ghostty_surface_quicklook_font(surfacePtr) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: plain, attributes: attributes)
    }

    // Cached 500ms because VoiceOver asks value, count, range and line in one burst.
    private func screenContents() -> String {
        let now = ContinuousClock.now
        if let cache = accessibilityContentsCache, now - cache.fetchedAt < .milliseconds(500) {
            return cache.value
        }
        let contents = readScreenText()
        accessibilityContentsCache = (contents, now)
        return contents
    }

    private func readScreenText() -> String {
        guard let surfacePtr else { return "" }
        var text = ghostty_text_s()
        let wholeScreen = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surfacePtr, wholeScreen, &text) else { return "" }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard let ptr = text.text else { return "" }
        return String(cString: ptr)
    }
}
