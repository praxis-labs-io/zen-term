import AppKit
import GhosttyKit

/// NSAccessibility for `GhosttyHostView` (ZEN-323), ported from ghostty's own `SurfaceView`
/// accessibility conformance. This is what makes the terminal readable to VoiceOver and other
/// assistive tools: the view answers as a single text area whose value is the full screen
/// contents (scrollback included).
///
/// The screen read is a synchronous in-memory copy on the main thread. That is deliberate
/// despite the no-main-thread-blocking rule: `ghostty_surface_read_text` must run where every
/// other surface call runs, it is a memory copy rather than I/O, it only executes while an
/// assistive client is querying, and the cache below bounds how often a query burst pays it.
extension GhosttyHostView {
    override func isAccessibilityElement() -> Bool { true }

    // A text area rather than a static text element: the terminal is a place users both read
    // and type, and the role decides which navigation commands VoiceOver offers.
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
        // Count separators rather than splitting: VoiceOver walks lines one query at a
        // time, and a components() split re-allocates every line above the probe on each.
        let prefix = contents.substring(to: clamped)
        return prefix.unicodeScalars.lazy.filter(CharacterSet.newlines.contains).count
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let contents = screenContents() as NSString
        // Assistive clients probe with ranges from earlier snapshots — including NSNotFound
        // and near-Int.max values — so out-of-bounds is an expected answer, not a programmer
        // error. Subtraction, not NSMaxRange: the addition inside NSMaxRange wraps on those
        // probes, slips past a `<= length` check, and the range then raises in substring.
        guard range.location >= 0, range.length >= 0,
            range.location <= contents.length,
            range.length <= contents.length - range.location
        else { return nil }
        return contents.substring(with: range)
    }

    /// Carries the terminal's font so VoiceOver renders what it reads; styling beyond the font
    /// would need ghostty core to expose it (its own app has the same limit).
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let plain = accessibilityString(for: range) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let surfacePtr, let fontRaw = ghostty_surface_quicklook_font(surfacePtr) {
            // The C side hands back a +1 CTFont; take it unretained and balance the retain
            // ourselves, matching ghostty's own handling.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: plain, attributes: attributes)
    }

    /// The full screen contents, cached briefly. VoiceOver asks in bursts — value, count,
    /// range, line — and each answer derives from this one string; without the cache every
    /// question in a burst would re-copy the whole scrollback.
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
