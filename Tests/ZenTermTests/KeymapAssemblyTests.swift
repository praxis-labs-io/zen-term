import XCTest

@testable import ZenTerm

final class KeymapAssemblyTests: XCTestCase {
    private func float(id: String, key: String) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: "square.on.square", command: "run",
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            emptyGuard: nil, toggle: Chord.parse(key)!)
    }

    func test_defaultsPresent() {
        let map = KeymapAssembler.assemble(floats: [], keybinds: [])
        XCTAssertEqual(map[Chord(command: true, key: "f")], .toggleZoom)
        // The ⌘⇧\ shifted-symbol quirk: both "|" and "\\" map to splitVertical.
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "|")], .splitVertical)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "\\")], .splitVertical)
        // Horizontal split is ⌘⇧- (ZEN-142) — bare ⌘- is left free for ghostty text magnification.
        // Like ⌘⇧\, the shifted-symbol quirk means a live event decodes to "_", so both map.
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "_")], .splitHorizontal)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitHorizontal)
        XCTAssertNil(map[Chord(command: true, key: "-")])
        XCTAssertEqual(map[Chord(command: true, option: true, key: "r")], .reloadConfig)
    }

    func test_userRebind_shiftedSymbol_bindsBothGlyphsOfThePhysicalKey() {
        // The trap this guards: a hand-written (or captured-then-written) `split_horizontal=cmd+shift+-`
        // parses to the base "-", but a live ⌘⇧- press decodes to "_" (charactersIgnoringModifiers
        // applies Shift). Binding only "-" would leave the rebind dead. The assembler binds both.
        let user = KeybindParser.parse("split_horizontal=cmd+shift+-")!
        let map = KeymapAssembler.assemble(floats: [], keybinds: [user])
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitHorizontal)  // written form
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "_")], .splitHorizontal)  // live-event form
    }

    func test_userRebind_writtenAsShiftedGlyph_alsoBindsBase() {
        // The mirror case: config emitted from a UI capture stores the live glyph ("_"); the base
        // "-" sibling must come along so both spellings resolve identically.
        let user = KeybindParser.parse("split_vertical=cmd+shift+_")!
        let map = KeymapAssembler.assemble(floats: [], keybinds: [user])
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "_")], .splitVertical)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitVertical)
    }

    func test_floatChord_overridesBuiltin() {
        // A float claiming ⌘G displaces the built-in .toggleLazygit.
        let map = KeymapAssembler.assemble(floats: [float(id: "x", key: "cmd+g")], keybinds: [])
        XCTAssertEqual(map[Chord(command: true, key: "g")], .toggleToolFloat("x"))
    }

    func test_userKeybind_overridesFloatChord() {
        let floats = [float(id: "x", key: "cmd+shift+l")]
        let keybinds: [(Chord, KeyInterceptor.ReservedChord)] = [
            (Chord(command: true, shift: true, key: "l"), .toggleZoom)
        ]
        let map = KeymapAssembler.assemble(floats: floats, keybinds: keybinds)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "l")], .toggleZoom)
    }

    func test_rebind_freesActionsDefaultChord() {
        // Rebinding new_tab to ⌘Y must release its default ⌘T, not leave both bound.
        let keybinds: [(Chord, KeyInterceptor.ReservedChord)] = [
            (Chord(command: true, key: "y"), .newTab)
        ]
        let map = KeymapAssembler.assemble(floats: [], keybinds: keybinds)
        XCTAssertEqual(map[Chord(command: true, key: "y")], .newTab)
        XCTAssertNil(map[Chord(command: true, key: "t")])  // old default freed
    }

    func test_lastKeybindWins() {
        let chord = Chord(command: true, key: "f")
        let keybinds: [(Chord, KeyInterceptor.ReservedChord)] = [
            (chord, .toggleBottomDrawer), (chord, .toggleRightDrawer),
        ]
        let map = KeymapAssembler.assemble(floats: [], keybinds: keybinds)
        XCTAssertEqual(map[chord], .toggleRightDrawer)
    }

    func test_toggleFloatKeybind_forUnknownID_isDropped() {
        let keybinds: [(Chord, KeyInterceptor.ReservedChord)] = [
            (Chord(command: true, key: "y"), .toggleToolFloat("ghost"))
        ]
        let map = KeymapAssembler.assemble(floats: [], keybinds: keybinds)
        XCTAssertNil(map[Chord(command: true, key: "y")])  // no such float → not bound
    }
}
