import AppKit

// `KeyInterceptor` resolves a chord before any menu key equivalent, so a keymap entry on a menu chord kills the item.
enum MenuShortcuts {
    @MainActor
    static func protected() -> Set<Chord> {
        guard let menu = mainMenu else { return [] }
        var chords: Set<Chord> = []
        collect(from: menu, into: &chords)
        return chords
    }

    @MainActor
    static func owner(of chord: Chord) -> String? {
        guard let menu = mainMenu else { return nil }
        var owners: [Chord: String] = [:]
        collectOwners(from: menu, into: &owners)
        return owners[chord]
    }

    // `NSApp` is nil in a test process that never made an application, and unwrapping it crashes the suite.
    @MainActor
    private static var mainMenu: NSMenu? {
        guard let app = NSApp else { return nil }
        return app.mainMenu
    }

    private static func collect(from menu: NSMenu, into chords: inout Set<Chord>) {
        for item in menu.items {
            if let chord = self.chord(for: item) { chords.insert(chord) }
            if let submenu = item.submenu { collect(from: submenu, into: &chords) }
        }
    }

    private static func collectOwners(from menu: NSMenu, into owners: inout [Chord: String]) {
        for item in menu.items {
            if let chord = self.chord(for: item), owners[chord] == nil { owners[chord] = item.title }
            if let submenu = item.submenu { collectOwners(from: submenu, into: &owners) }
        }
    }

    // An uppercase key equivalent carries Shift on its own, the way AppKit draws and matches it.
    static func chord(for item: NSMenuItem) -> Chord? {
        let key = item.keyEquivalent
        guard key.count == 1 else { return nil }
        let mask = item.keyEquivalentModifierMask
        let shift = mask.contains(.shift) || key != key.lowercased()
        guard mask.contains(.command) || shift || mask.contains(.option) || mask.contains(.control)
        else { return nil }
        return Chord(
            command: mask.contains(.command), shift: shift,
            option: mask.contains(.option), control: mask.contains(.control), key: key)
    }
}
