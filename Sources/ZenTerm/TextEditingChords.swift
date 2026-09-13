import AppKit

/// The keymap chords a focused text view owns ahead of ZenTerm.
enum TextEditingChords {
    /// No ⌘A: AppKit serves Select All from the Edit menu, not from `NSTextView`.
    private static let owned: Set<Chord> = [
        Chord(command: true, shift: true, key: "↑"),
        Chord(command: true, shift: true, key: "↓"),
        Chord(command: true, key: "⏎"),
        Chord(command: true, shift: true, key: "⏎"),
    ]

    /// A focused field's editor is an `NSTextView`, so this covers fields too.
    static func owns(_ chord: Chord, firstResponder: NSResponder?) -> Bool {
        guard firstResponder is NSTextView else { return false }
        return owned.contains(chord)
    }
}
