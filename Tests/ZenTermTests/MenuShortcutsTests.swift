import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class MenuShortcutsTests: XCTestCase {
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

    func test_aMenuItemsKeyEquivalentReadsAsItsChord() throws {
        let item = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")
        item.keyEquivalentModifierMask = [.command]
        XCTAssertEqual(MenuShortcuts.chord(for: item), Chord(command: true, key: "q"))
    }

    func test_aShiftedKeyEquivalentFoldsTheSameWayALiveChordDoes() throws {
        let item = NSMenuItem(title: "Split", action: nil, keyEquivalent: "_")
        item.keyEquivalentModifierMask = [.command, .shift]
        XCTAssertEqual(MenuShortcuts.chord(for: item), Chord(command: true, shift: true, key: "-"))
    }

    func test_anItemWithNoKeyEquivalentClaimsNothing() {
        XCTAssertNil(MenuShortcuts.chord(for: NSMenuItem(title: "About", action: nil, keyEquivalent: "")))
    }

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

    func test_noShippedDefaultTakesAMenuShortcut() {
        MainMenu.install()
        let protected = MenuShortcuts.protected()
        XCTAssertTrue(protected.contains(Chord(command: true, key: "q")), "⌘Q must read as protected")
        let collisions = KeymapDefaults.map.keys.filter { protected.contains($0) }
        XCTAssertEqual(
            collisions.map(\.displayGlyph).sorted(), [],
            "a default keybind on a menu chord kills the menu item silently, because the key "
                + "monitor resolves before NSApp.sendEvent")
    }

    func test_theMenuClaimsNothingTheKeymapAlreadyHolds() {
        MainMenu.install()
        let protected = MenuShortcuts.protected()
        XCTAssertTrue(protected.contains(Chord(command: true, key: "q")), "⌘Q must read as protected")
        let taken = protected.filter { KeymapDefaults.map[$0] != nil }
        XCTAssertEqual(taken.map(\.displayGlyph).sorted(), [])
    }

    func test_selectAllIsTheMenusChord() {
        MainMenu.install()
        XCTAssertEqual(MenuShortcuts.owner(of: Chord(command: true, key: "a")), "Select All")
    }

    func test_aUserBindOnAMenuChordIsDroppedAndReported() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [.bind(Chord(command: true, key: "q"), .newTab)],
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

    func test_aRefusedBindLeavesTheActionsDefaultAlone() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [.bind(Chord(command: true, key: "q"), .newTab)],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in "Quit ZenTerm" })

        XCTAssertEqual(
            result.map[Chord(command: true, key: "t")], .newTab,
            "new_tab keeps ⌘T; only the refused line is dropped")
    }

    func test_anUppercaseKeyEquivalentCarriesShiftOnItsOwn() {
        let item = NSMenuItem(title: "Save As…", action: nil, keyEquivalent: "S")
        item.keyEquivalentModifierMask = [.command]
        XCTAssertEqual(
            MenuShortcuts.chord(for: item), Chord(command: true, shift: true, key: "s"),
            "⌘⇧S is what macOS matches, so ⌘⇧S is what has to be protected")
    }

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

    func test_aFloatWithARefusedKeyIsStillConfigured() {
        let float = ToolFloat(
            id: "notes", order: 0, title: "Notes", icon: ToolFloatParser.defaultIcon, command: "ls",
            dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, key: "q"))

        let result = KeymapAssembler.assemble(
            floats: [float], keybinds: [.bind(Chord(command: true, option: true, key: "n"), .toggleToolFloat("notes"))],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in "Quit ZenTerm" })

        XCTAssertEqual(
            result.map[Chord(command: true, option: true, key: "n")], .toggleToolFloat("notes"),
            "a keybind naming the float still resolves, so the float is still configured")
    }

    func test_aRefusedBindWithNoNamedOwnerStillReadsAsASentence() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [.bind(Chord(command: true, key: "q"), .newTab)],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in nil })

        let diagnostic = try? XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic?.message, "new_tab=cmd+q is a menu shortcut. Ignoring it.")
        XCTAssertEqual(diagnostic?.detail, "cmd+q → the menu")
    }

    func test_aBindOnAFreeChordIsUnaffected() {
        let result = KeymapAssembler.assemble(
            floats: [], keybinds: [.bind(Chord(command: true, option: true, key: "n"), .newTab)],
            canType: { _ in true },
            protected: { [Chord(command: true, key: "q")] },
            menuOwner: { _ in nil })

        XCTAssertEqual(result.map[Chord(command: true, option: true, key: "n")], .newTab)
        XCTAssertEqual(result.diagnostics, [])
    }
}
