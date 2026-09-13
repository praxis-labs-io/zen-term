import AppKit
import GhosttyKit

// Accents, dead keys, the emoji picker, CJK and dictation, ported from ghostty's `SurfaceView`.
extension GhosttyHostView: NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surfacePtr else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    // Outside `keyDown`, such as a layout switch mid-composition, nothing else syncs the preedit.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: value)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            break
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    // Always returns the selection: macOS asks for bogus ranges, and ghostty's own client does the same.
    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let surfacePtr, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard let ptr = text.text else { return nil }
        return NSAttributedString(string: String(cString: ptr))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // Zero width for an empty range, or dictation's microphone indicator mis-anchors.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surfacePtr else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surfacePtr, &x, &y, &width, &height)
        if range.length == 0 { width = 0 }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: height)
        let windowRect = convert(viewRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil, let surfacePtr else { return }
        let chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as String: chars = value
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        let byteCount = UInt(chars.utf8.count)
        chars.withCString { ghostty_surface_text(surfacePtr, $0, byteCount) }
    }

    // Swallows selectors to silence the bell; libghostty encodes those keys from the raw event in `keyDown`.
    override func doCommand(by selector: Selector) {
        if let event = eventToRedispatch(NSApp.currentEvent) { NSApp.sendEvent(event) }
    }

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surfacePtr else { return }
        if markedText.length > 0 {
            let preedit = markedText.string
            let byteCount = UInt(preedit.utf8.count)
            if byteCount > 0 {
                preedit.withCString { ghostty_surface_preedit(surfacePtr, $0, byteCount) }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surfacePtr, nil, 0)
        }
    }
}
