import AppKit

/// The chords the menu bar owns, which the keymap may never take.
///
/// `KeyInterceptor` is a local `NSEvent` monitor, so it resolves a chord *before* `NSApp.sendEvent`
/// gets to match it against a menu item's key equivalent. A keymap entry on a menu chord therefore
/// wins every time, the menu item never fires, and the menu keeps drawing the shortcut beside it.
/// Nothing about that is visible from either side: the menu looks bound and the keybind works.
///
/// Read from `NSApp.mainMenu` rather than hand-listed, so a menu item added later is protected with
/// no list to update. That matters more than it sounds: this guard exists because ⌘⇧H was given to
/// Hide and to `resize_left` by two separate changes, neither of which had anything to check.
enum MenuShortcuts {
    /// Every chord the current menu bar claims, submenus included.
    ///
    /// Main-thread-only, like every `NSApp` read. `KeymapAssembler` is already `@MainActor` for the
    /// same reason `KeyboardLayout` is.
    @MainActor
    static func protected() -> Set<Chord> {
        guard let menu = mainMenu else { return [] }
        var chords: Set<Chord> = []
        collect(from: menu, into: &chords)
        return chords
    }

    /// Which menu item owns a chord, for a diagnostic that has to name it. Nil when none does.
    @MainActor
    static func owner(of chord: Chord) -> String? {
        guard let menu = mainMenu else { return nil }
        var owners: [Chord: String] = [:]
        collectOwners(from: menu, into: &owners)
        return owners[chord]
    }

    /// `NSApp` is implicitly unwrapped and is nil in a process that never made an application,
    /// which every test target is until something touches `NSApplication.shared`. Reading
    /// `NSApp.mainMenu` there is a nil-unwrap crash that takes the whole suite down rather than
    /// failing one case, and this is reached from `KeymapAssembler.assemble` by default, so any
    /// test that assembles a keymap would hit it. No app means no menu means nothing protected.
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

    /// The chord a menu item claims, or nil for an item with no key equivalent.
    ///
    /// Built through `Chord`'s own initializer so the shifted-glyph fold applies here too: a menu
    /// item spelled `"h"` with a Shift mask and a live ⌘⇧H press have to land on the same value, or
    /// the guard compares two spellings of one key and finds no collision.
    ///
    /// A modifier-less key equivalent is skipped rather than protected. `Chord.parse` rejects those
    /// for the keymap already, so no bind can collide with one, and protecting them would be a set
    /// of entries nothing can ever match.
    /// An uppercase key equivalent carries Shift on its own. AppKit's convention is that
    /// `keyEquivalent: "S"` with a bare `.command` mask means ⇧⌘S, and macOS both draws and
    /// matches it that way, so reading Shift from the mask alone would protect ⌘S and leave the
    /// item's real ⌘⇧S open. That is this guard failing at precisely the job it exists for, and it
    /// would go unnoticed: a test comparing the menu against the keymap compares the same wrong
    /// chord on both sides.
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
