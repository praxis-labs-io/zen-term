import ControlProtocol
import TerminalKit

extension TerminalKey {
    // Escape has no `Chord` glyph, since no shortcut is bound to it.
    static let escape = TerminalKey(keyCode: 53, modifiers: [])

    @MainActor
    init?(paneKey: PaneKey) {
        switch paneKey {
        case .escape: self = .escape
        case .enter: self.init(chord: Chord(key: "⏎"))
        case .tab: self.init(chord: Chord(key: "⇥"))
        case .shiftTab: self.init(chord: Chord(shift: true, key: "⇥"))
        case .backspace: self.init(chord: Chord(key: "⌫"))
        case .space: self.init(chord: Chord(key: " "))
        case .up: self.init(chord: Chord(key: "↑"))
        case .down: self.init(chord: Chord(key: "↓"))
        case .left: self.init(chord: Chord(key: "←"))
        case .right: self.init(chord: Chord(key: "→"))
        case .home: self.init(chord: Chord(key: "↖"))
        case .end: self.init(chord: Chord(key: "↘"))
        case .pageUp: self.init(chord: Chord(key: "⇞"))
        case .pageDown: self.init(chord: Chord(key: "⇟"))
        case .control(let letter): self.init(chord: Chord(control: true, key: String(letter)))
        }
    }
}
