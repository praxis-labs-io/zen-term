import AppKit
import XCTest

@testable import ZenTerm

/// The menu bar and the keymap both claim chords, and the keymap wins every time: `KeyInterceptor`
/// is a local `NSEvent` monitor, so it resolves before `NSApp.sendEvent` ever matches a key
/// equivalent. Nothing checked that, and it cost Hide its shortcut for however long ⌘⇧H has been
/// `resize_left`. The menu still drew ⌘⇧H beside a dead item the whole time.
@MainActor
final class MenuShortcutsTests: XCTestCase {
    /// `MainMenu.install` writes `NSApp.mainMenu`, which is process-global and outlives the test
    /// that set it. Restored per case so a later test in the same run sees whatever menu it
    /// expected rather than ours, the same save/restore `MainMenuTests` does.
    private var savedMenu: NSMenu?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedMenu = NSApp.mainMenu
    }

    override func tearDown() {
        NSApp.mainMenu = savedMenu
        super.tearDown()
    }

    // MARK: Reading the menu

    func test_aMenuItemsKeyEquivalentReadsAsItsChord() throws {
        let item = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")
        item.keyEquivalentModifierMask = [.command]
        XCTAssertEqual(MenuShortcuts.chord(for: item), Chord(command: true, key: "q"))
    }

    /// Through `Chord`'s own initializer, so the shifted-glyph fold applies on both sides. A menu
    /// item spelled `"-"` with a Shift mask and a live ⌘⇧- press (which arrives as `_`) have to
    /// land on one value, or the guard compares two spellings of one key and sees no collision.
    func test_aShiftedKeyEquivalentFoldsTheSameWayALiveChordDoes() throws {
        let item = NSMenuItem(title: "Split", action: nil, keyEquivalent: "_")
        item.keyEquivalentModifierMask = [.command, .shift]
        XCTAssertEqual(MenuShortcuts.chord(for: item), Chord(command: true, shift: true, key: "-"))
    }

    func test_anItemWithNoKeyEquivalentClaimsNothing() {
        XCTAssertNil(MenuShortcuts.chord(for: NSMenuItem(title: "About", action: nil, keyEquivalent: "")))
    }

    /// `Chord.parse` rejects a modifier-less bind, so no keybind can ever collide with one.
    /// Protecting them would be entries nothing can match.
    func test_aModifierLessKeyEquivalentIsNotProtected() {
        let item = NSMenuItem(title: "Odd", action: nil, keyEquivalent: "x")
        item.keyEquivalentModifierMask = []
        XCTAssertNil(MenuShortcuts.chord(for: item))
    }

    func test_protectedReachesIntoSubmenus() {
        let main = NSMenu()
        let top = NSMenuItem()
        let sub = NSMenu()
        let item = NSMenuItem(title: "Deep", action: nil, keyEquivalent: "d")
        item.keyEquivalentModifierMask = [.command, .option]
        sub.addItem(item)
        top.submenu = sub
        main.addItem(top)

        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        NSApp.mainMenu = main

        XCTAssertTrue(MenuShortcuts.protected().contains(Chord(command: true, option: true, key: "d")))
        XCTAssertEqual(MenuShortcuts.owner(of: Chord(command: true, option: true, key: "d")), "Deep")
    }

    // MARK: The guard on our own defaults

    /// The test that would have caught the Hide collision. It covers our shipped defaults against
    /// the real menu, so this is the one that goes red if someone gives a menu item a chord the
    /// keymap already holds, in either direction.
    func test_noShippedDefaultTakesAMenuShortcut() {
        MainMenu.install(copyPaste: nil)
        let protected = MenuShortcuts.protected()
        // An empty protected set intersects nothing, so the guard below would pass with the menu
        // read dead. Anchor on a chord the menu bar always holds before trusting the emptiness.
        XCTAssertTrue(protected.contains(Chord(command: true, key: "q")), "⌘Q must read as protected")
        let collisions = KeymapDefaults.map.keys.filter { protected.contains($0) }
        XCTAssertEqual(
            collisions.map(\.displayGlyph).sorted(), [],
            "a default keybind on a menu chord kills the menu item silently, because the key "
                + "monitor resolves before NSApp.sendEvent")
    }

    /// The other half, in the direction that actually broke: the menu must not hand out a chord
    /// the keymap holds. Same set, but asserting it from the menu's side names the real failure.
    func test_theMenuClaimsNothingTheKeymapAlreadyHolds() {
        MainMenu.install(copyPaste: nil)
        let protected = MenuShortcuts.protected()
        XCTAssertTrue(protected.contains(Chord(command: true, key: "q")), "⌘Q must read as protected")
        let taken = protected.filter { KeymapDefaults.map[$0] != nil }
        XCTAssertEqual(taken.map(\.displayGlyph).sorted(), [])
    }

    // MARK: Refusing a bind

    func test_aUserBindOnAMenuChordIsDroppedAndReported() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [(Chord(command: true, key: "q"), .newTab)],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in "Quit ZenTerm" })

        XCTAssertNil(result.map[Chord(command: true, key: "q")], "⌘Q must stay with the menu")
        XCTAssertEqual(
            result.diagnostics,
            [
                ConfigDiagnostic(
                    scope: .keybind(.newTab),
                    problem: .menuBind(Chord(command: true, key: "q"), menuItem: "Quit ZenTerm"))
            ])
    }

    /// A refused line must not also cost the action its default, the same rule an untypeable line
    /// follows. Dropping both would leave the action unreachable and look like it was bound.
    func test_aRefusedBindLeavesTheActionsDefaultAlone() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [(Chord(command: true, key: "q"), .newTab)],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in "Quit ZenTerm" })

        XCTAssertEqual(
            result.map[Chord(command: true, key: "t")], .newTab,
            "new_tab keeps ⌘T; only the refused line is dropped")
    }

    /// AppKit's own spelling for a shifted menu shortcut is an uppercase key equivalent with a
    /// bare ⌘ mask, and macOS draws and matches that as ⇧⌘S. Reading Shift from the mask alone
    /// protected the wrong chord and left the item's real one open, which is this guard failing at
    /// the job it exists for.
    func test_anUppercaseKeyEquivalentCarriesShiftOnItsOwn() {
        let item = NSMenuItem(title: "Save As…", action: nil, keyEquivalent: "S")
        item.keyEquivalentModifierMask = [.command]
        XCTAssertEqual(
            MenuShortcuts.chord(for: item), Chord(command: true, shift: true, key: "s"),
            "⌘⇧S is what macOS matches, so ⌘⇧S is what has to be protected")
    }

    /// A float's `key:` is refused on the same grounds and reported against the float, not a
    /// keybind: the user wrote it on the `float =` line, which is where they have to go to fix it.
    func test_aFloatKeyOnAMenuChordIsDroppedAndReportedAgainstTheFloat() {
        let float = ToolFloat(
            id: "notes", order: 0, title: "Notes", icon: ToolFloatParser.defaultIcon, command: "ls",
            dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, key: "q"))

        let result = KeymapAssembler.assemble(
            floats: [float], keybinds: [], canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in "Quit ZenTerm" })

        XCTAssertNil(result.map[Chord(command: true, key: "q")], "⌘Q must stay with the menu")
        XCTAssertEqual(
            result.diagnostics,
            [
                ConfigDiagnostic(
                    scope: .toolFloatField(id: "notes", label: "Notes"),
                    problem: .floatMenuKey(Chord(command: true, key: "q"), menuItem: "Quit ZenTerm"))
            ],
            "the float survives, so this belongs on its row and not in the dropped-float notice")
    }

    /// The rendered sentence, not just the diagnostic's identity. A float has no action token to
    /// lean on, so reusing the keybind case left the message starting with a bare `=`.
    func test_aRefusedFloatKeyReadsAsASentence() throws {
        let float = ToolFloat(
            id: "notes", order: 0, title: "Notes", icon: ToolFloatParser.defaultIcon, command: "ls",
            dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, key: "q"))

        let result = KeymapAssembler.assemble(
            floats: [float], keybinds: [], canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in "Quit ZenTerm" })

        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.message, "key:cmd+q is the Quit ZenTerm menu shortcut. Ignoring it.")
        XCTAssertEqual(diagnostic.headline, "Notes")
    }

    /// The float itself survives; only its chord is refused. Dropping the float would lose a tool
    /// over a shortcut, and it is still reachable from the palette and the toolbar.
    func test_aFloatWithARefusedKeyIsStillConfigured() {
        let float = ToolFloat(
            id: "notes", order: 0, title: "Notes", icon: ToolFloatParser.defaultIcon, command: "ls",
            dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, key: "q"))

        let result = KeymapAssembler.assemble(
            floats: [float], keybinds: [(Chord(command: true, option: true, key: "n"), .toggleToolFloat("notes"))],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in "Quit ZenTerm" })

        XCTAssertEqual(
            result.map[Chord(command: true, option: true, key: "n")], .toggleToolFloat("notes"),
            "a keybind naming the float still resolves, so the float is still configured")
    }

    /// The owner is optional because the menu can answer "protected" without the lookup finding a
    /// title. Both renderings have to stay grammatical, which a placeholder word did not: the
    /// message read "is the a menu shortcut".
    func test_aRefusedBindWithNoNamedOwnerStillReadsAsASentence() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [(Chord(command: true, key: "q"), .newTab)],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in nil })

        let diagnostic = try? XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic?.message, "new_tab=cmd+q is a menu shortcut. Ignoring it.")
        XCTAssertEqual(diagnostic?.detail, "cmd+q → the menu")
    }

    func test_aBindOnAFreeChordIsUnaffected() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [(Chord(command: true, option: true, key: "n"), .newTab)],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in nil })

        XCTAssertEqual(result.map[Chord(command: true, option: true, key: "n")], .newTab)
        XCTAssertEqual(result.diagnostics, [])
    }
}
