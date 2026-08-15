import AppKit
import GhosttyKit

/// IME / dead-key composition for `GhosttyHostView`, ported from ghostty's own
/// `SurfaceView` `NSTextInputClient` conformance and adapted to our thinner embed (no
/// surface-model indirection, no QuickLook selection path). This is what makes
/// press-and-hold accents, Option dead keys, the emoji picker, CJK input, and dictation
/// compose; `GhosttyHostView.keyDown` drives it via `interpretKeyEvents`.
extension GhosttyHostView: NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surfacePtr else { return NSRange() }
        // There's an inherent race between reading the range and using it (the selection
        // can move), but AppKit offers no better contract here.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: value)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            break
        }
        // Outside a keyDown — e.g. switching keyboard layouts mid-composition — nothing
        // will sync the preedit for us, so push it now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let surfacePtr, range.length > 0 else { return nil }
        // macOS asks for all sorts of bogus ranges here; ghostty's own client just always
        // returns the current selection and it works, so we do the same.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surfacePtr, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        guard let ptr = text.text else { return nil }
        return NSAttributedString(string: String(cString: ptr))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surfacePtr else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        // libghostty tells us where the IME candidate window should anchor: the cursor's
        // top-left in px plus its cell width/height.
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surfacePtr, &x, &y, &width, &height)
        // Dictation queries with an empty range; a positive width there mis-anchors the
        // microphone indicator, so zero it (matches ghostty's own firstRect).
        if range.length == 0 { width = 0 }
        // Two conversions the OS requires: ghostty's top-left origin → AppKit's
        // bottom-left, then view → window → screen coordinates.
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

        // insertText means the composition is finished.
        unmarkText()

        // Inside a keyDown, queue the text so the keyDown flow encodes it as a key event.
        // Standalone (dictation, the character/emoji palette), commit straight to the pty.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        let byteCount = UInt(chars.utf8.count)
        chars.withCString { ghostty_surface_text(surfacePtr, $0, byteCount) }
    }

    /// Exists so unhandled selectors don't ring the system bell. The keys these selectors
    /// stand for (Return, Backspace, arrows, …) are still encoded by libghostty from the
    /// raw key event back in `keyDown` after `interpretKeyEvents` returns, so swallowing
    /// the selector here only suppresses AppKit's default text-field behavior.
    override func doCommand(by selector: Selector) {
        // A command key AppKit redirected here instead of to `keyDown`: send it back through the
        // event system, where `performKeyEquivalent` knows the timestamp and routes it on.
        if let current = NSApp.currentEvent, lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    /// Push the current marked-text state into libghostty. When the preedit has just gone
    /// empty (a composition ended), clear it so no stale underline lingers.
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
