import AppKit

// What a key the person typed into a pane does to the text sitting unsent at its prompt.
enum DraftEdit: Equatable {
    case add(String), addUnknown, removeOne, removeUnknown, move, submit, clear, stash, none

    private static let returnKeys: Set<UInt16> = [36, 76]
    private static let backspaceKey: UInt16 = 51
    private static let forwardDeleteKey: UInt16 = 117
    // Up, Down and Tab recall or complete text at an agent's prompt.
    private static let recallingKeys: Set<UInt16> = [126, 125, 48]
    // Left, Right, Home and End move the cursor and leave the text as it was.
    private static let movingKeys: Set<UInt16> = [123, 124, 115, 119]
    private static let clearingControlKeys: Set<String> = ["c", "u"]
    private static let deletingControlKeys: Set<String> = ["h", "k", "w"]
    private static let movingControlKeys: Set<String> = ["a", "b", "e", "f"]
    private static let functionKeys: ClosedRange<UInt32> = 0xF700...0xF8FF

    // While an input method composes, a key edits its marked text, and only it knows what reaches the prompt.
    init(_ event: NSEvent, composing: Bool) {
        let edit = DraftEdit(event)
        self = composing && edit != .none && edit != .clear ? .addUnknown : edit
    }

    private init(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if Self.returnKeys.contains(event.keyCode) {
            self = modifiers.isEmpty ? .submit : .add("\n")
        } else if Self.recallingKeys.contains(event.keyCode) {
            self = modifiers.isEmpty ? .addUnknown : .none
        } else if Self.movingKeys.contains(event.keyCode) {
            self = .move
        } else if event.keyCode == Self.backspaceKey {
            self = modifiers.isEmpty ? .removeOne : .removeUnknown
        } else if event.keyCode == Self.forwardDeleteKey {
            self = .removeUnknown
        } else if modifiers == .control {
            self = Self.controlEdit(event.charactersIgnoringModifiers?.lowercased() ?? "")
        } else if modifiers.isDisjoint(with: [.command, .control]), let typed = Self.typed(event.characters) {
            self = .add(typed)
        } else {
            self = .none
        }
    }

    private static func controlEdit(_ key: String) -> DraftEdit {
        if clearingControlKeys.contains(key) { return .clear }
        if movingControlKeys.contains(key) { return .move }
        return deletingControlKeys.contains(key) ? .removeUnknown : .none
    }

    private static func typed(_ characters: String?) -> String? {
        guard let characters, !characters.isEmpty else { return nil }
        let printable = characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !functionKeys.contains($0.value)
        }
        return printable ? characters : nil
    }
}
