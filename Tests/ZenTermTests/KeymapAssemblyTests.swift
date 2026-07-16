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
