import AppKit

// What a key the person typed into a pane does to the text sitting unsent at its prompt.
enum DraftEdit: Equatable {
    case write, submit, clear, none

    private static let returnKeys: Set<UInt16> = [36, 76]
    // Up, Down and Tab recall or complete text at an agent's prompt.
    private static let recallingKeys: Set<UInt16> = [126, 125, 48]
    private static let clearingControlKeys: Set<String> = ["c", "u"]
    private static let functionKeys: ClosedRange<UInt32> = 0xF700...0xF8FF

    init(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if Self.returnKeys.contains(event.keyCode) {
            self = modifiers.isEmpty ? .submit : .write
        } else if Self.recallingKeys.contains(event.keyCode) {
            self = modifiers.isEmpty ? .write : .none
        } else if modifiers == .control {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            self = Self.clearingControlKeys.contains(key) ? .clear : .none
        } else if modifiers.isDisjoint(with: [.command, .control]), Self.types(event.characters) {
            self = .write
        } else {
            self = .none
        }
    }

    private static func types(_ characters: String?) -> Bool {
        guard let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !functionKeys.contains($0.value)
        }
    }
}
