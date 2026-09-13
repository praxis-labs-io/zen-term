import XCTest

@testable import ZenTerm

final class KeymapAssemblyTests: XCTestCase {
    private func float(id: String, key: String) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: "square.on.square", command: "run", dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord.parse(key)!)
    }

    private func assemble(
        floats: [ToolFloat] = [], keybinds: [KeybindParser.Line] = []
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        KeymapAssembler.assemble(floats: floats, keybinds: keybinds).map
    }

    func test_floatHiddenFromToolbar_stillBindsItsChord() {
        var spec = float(id: "dev", key: "cmd+shift+j")
        spec.showsInToolbar = false
        let map = assemble(floats: [spec])
        XCTAssertEqual(map[Chord.parse("cmd+shift+j")!], .toggleToolFloat("dev"))
    }

    func test_defaultsPresent() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "f")], .toggleSearch)
        XCTAssertEqual(map[Chord(command: true, key: "⏎")], .fillScreen)
        XCTAssertEqual(map[Chord(command: true, key: "d")], .splitVertical)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: ",")], .reloadConfig)
    }

    func test_theMovedChords_areOnlyAtTheirNewHomes() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "d")], .splitHorizontal)
        XCTAssertEqual(map[Chord(command: true, key: "j")], .scrollToSelection)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "⏎")], .toggleZoom)
        XCTAssertEqual(map[Chord(command: true, key: "p")], .toggleRepoPicker)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "p")], .toggleCommandPalette)

        XCTAssertNil(map[Chord(command: true, shift: true, key: "\\")], "⌘⇧\\ retired with the split")
        XCTAssertNil(map[Chord(command: true, shift: true, key: "-")], "and so did ⌘⇧-")
        XCTAssertNil(map[Chord(command: true, shift: true, key: "f")], "⌘⇧F retired with Fill Screen")
        XCTAssertEqual(map[Chord(command: true, key: "-")], .decreaseFontSize, "⌘- was never a split")
    }

    func test_paneDirectionals_areOnGhosttysArrowsAlone() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, option: true, key: "↑")], .navUp)
        XCTAssertEqual(map[Chord(command: true, control: true, key: "←")], .resizeLeft)

        XCTAssertNil(map[Chord(command: true, shift: true, key: "h")], "⌘⇧hjkl resize retired")
        XCTAssertNotEqual(map[Chord(command: true, key: "k")], .navUp, "and ⌘hjkl nav with it")
    }

    func test_theScreenActions_tookTheChordsNavAndResizeGaveUp() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "k")], .clearScreen)
        XCTAssertEqual(map[Chord(command: true, key: "j")], .scrollToSelection)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "j")], .writeScreenFile)
    }

    func test_selectAll_shipsNoChord() {
        let map = assemble()
        XCTAssertNil(map[Chord(command: true, key: "a")], "⌘A is the Edit menu's")
        XCTAssertEqual(map.filter { $0.value == .selectAll }, [:])
    }

    func test_findStepping_holdsNoChord() {
        let map = assemble()
        XCTAssertEqual(map.filter { $0.value == .findNext }, [:])
        XCTAssertEqual(map.filter { $0.value == .findPrevious }, [:])
    }

    func test_commandG_isLeftFree() {
        XCTAssertNil(assemble()[Chord(command: true, key: "g")])
    }

    func test_theRemainingDuplicates_areGone() {
        let map = assemble()
        XCTAssertNil(map[Chord(control: true, key: "⇥")], "⌃⇥ tab cycling, ⌘] is the default")
        XCTAssertNil(map[Chord(shift: true, control: true, key: "⇥")], "and ⌃⇧⇥")
        XCTAssertNil(map[Chord(command: true, control: true, key: "f")], "⌃⌘F fill screen, ⌘⏎ is it")
        XCTAssertNil(map[Chord(command: true, key: "/")], "⌘/ find, ⌘F is it")
        XCTAssertNil(map[Chord(command: true, option: true, key: "r")], "⌘⌥R reload, ⌘⇧, is it")
    }

    func test_everyActionShipsOneChord_exceptIncrease() {
        var counts: [KeyInterceptor.ReservedChord: Int] = [:]
        for action in assemble().values { counts[action, default: 0] += 1 }
        XCTAssertEqual(
            counts.filter { $0.value > 1 }.map(\.key), [.increaseFontSize],
            "a second default chord needs a reason at the call site, and a line in this test")
    }

    func test_bothIncreaseChords_areBound() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "=")], .increaseFontSize)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "=")], .increaseFontSize)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "+")], .increaseFontSize)
        XCTAssertEqual(map[Chord(command: true, key: "0")], .resetFontSize)
    }

    func test_selectTab_doesNotClaimCmdZero() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "1")], .selectTab(1))
        XCTAssertEqual(map[Chord(command: true, key: "0")], .resetFontSize)
    }

    func test_rebindingIncrease_freesBothDefaultChords() {
        let map = assemble(keybinds: [.bind(Chord(command: true, option: true, key: "="), .increaseFontSize)])
        XCTAssertEqual(map[Chord(command: true, option: true, key: "=")], .increaseFontSize)
        XCTAssertNil(map[Chord(command: true, key: "=")])
        XCTAssertNil(map[Chord(command: true, shift: true, key: "=")])
    }

    func test_theShiftedSymbolDefault_holdsOneEntryNotTwo() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "+")], .increaseFontSize)
        XCTAssertEqual(map.filter { $0.value == .increaseFontSize }.count, 2)
    }

    func test_floatChord_overridesBuiltin() {
        let map = assemble(floats: [float(id: "x", key: "cmd+f")])
        XCTAssertEqual(map[Chord(command: true, key: "f")], .toggleToolFloat("x"))
    }

    func test_userKeybind_overridesFloatChord() {
        let map = assemble(
            floats: [float(id: "x", key: "cmd+shift+l")],
            keybinds: [.bind(Chord(command: true, shift: true, key: "l"), .toggleZoom)])
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "l")], .toggleZoom)
    }

    func test_rebind_freesActionsDefaultChord() {
        let map = assemble(keybinds: [.bind(Chord(command: true, key: "y"), .newTab)])
        XCTAssertEqual(map[Chord(command: true, key: "y")], .newTab)
        XCTAssertNil(map[Chord(command: true, key: "t")])
    }

    func test_rebindingShiftedSymbol_landsOnOneCanonicalChord() {
        let map = assemble(keybinds: [KeybindParser.parse("split_vertical=cmd+shift+-")!])
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitVertical)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "_")], .splitVertical)
        XCTAssertEqual(map.filter { $0.value == .splitVertical }.count, 1)
    }

    func test_lastKeybindWins() {
        let chord = Chord(command: true, key: "f")
        let map = assemble(keybinds: [.bind(chord, .toggleBottomDrawer), .bind(chord, .toggleRightDrawer)])
        XCTAssertEqual(map[chord], .toggleRightDrawer)
    }

    func test_toggleFloatKeybind_forUnknownID_isDropped() {
        let map = assemble(keybinds: [.bind(Chord(command: true, key: "y"), .toggleToolFloat("ghost"))])
        XCTAssertNil(map[Chord(command: true, key: "y")])
    }

    func test_scratchShipsOnCmdSemicolon() {
        XCTAssertEqual(assemble()[Chord(command: true, key: ";")], .toggleToolFloat("scratch"))
    }

    func test_scratchKeybind_isNotDroppedWithNoConfiguredFloats() {
        let map = assemble(
            floats: [], keybinds: [.bind(Chord(command: true, key: "y"), .toggleToolFloat("scratch"))])

        XCTAssertEqual(map[Chord(command: true, key: "y")], .toggleToolFloat("scratch"))
        XCTAssertNil(map[Chord(command: true, key: ";")], "a rebind moves it, leaving the default free")
    }

    func test_unbindingScratch_isHonored() {
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [.unbind(.toggleToolFloat("scratch"))])

        XCTAssertNil(assembled.map[Chord(command: true, key: ";")])
        XCTAssertEqual(assembled.unbound, [.toggleToolFloat("scratch")])
        XCTAssertEqual(assembled.diagnostics, [], "a config written on purpose says nothing")
    }

    func test_userFloatTakingScratchsChord_reportsItAgainstScratch() {
        let assembled = KeymapAssembler.assemble(
            floats: [float(id: "x", key: "cmd+;")], keybinds: [])

        XCTAssertEqual(assembled.map[Chord(command: true, key: ";")], .toggleToolFloat("x"))
        XCTAssertEqual(assembled.diagnostics.count, 1)
        XCTAssertEqual(assembled.diagnostics.first?.scope, .keybind(.toggleToolFloat("scratch")))
    }

    func test_scratchConflict_isAcceptableAndRevertable() {
        let taken = KeybindConflict(
            loser: .toggleToolFloat("scratch"), chord: Chord(command: true, key: ";"),
            winner: .newTab)
        XCTAssertTrue(taken.isAcceptable)

        let holding = KeybindConflict(
            loser: .newTab, chord: Chord(command: true, key: "t"),
            winner: .toggleToolFloat("scratch"))
        XCTAssertTrue(holding.isRevertable)
    }

    func test_unbindLine_leavesTheActionChordless_andSaysNothing() {
        let assembled = KeymapAssembler.assemble(
            floats: [float(id: "x", key: "cmd+j")], keybinds: [.unbind(.scrollToSelection)])

        XCTAssertEqual(assembled.map[Chord(command: true, key: "j")], .toggleToolFloat("x"))
        XCTAssertFalse(assembled.map.values.contains(.scrollToSelection))
        XCTAssertEqual(assembled.diagnostics, [], "an unbind the user asked for is not a problem")
        XCTAssertEqual(assembled.unbound, [.scrollToSelection])
    }

    func test_theSameCollisionWithoutTheLine_stillRecordsTheFact() {
        let assembled = KeymapAssembler.assemble(floats: [float(id: "x", key: "cmd+j")], keybinds: [])

        XCTAssertEqual(assembled.diagnostics.map(\.scope), [.keybind(.scrollToSelection)])
        XCTAssertEqual(assembled.unbound, [], "a displacement is not an intentional unbind")
    }

    func test_displacementLeavingNothing_isNotReportedAsUnbound() {
        let assembled = KeymapAssembler.assemble(floats: [float(id: "x", key: "cmd+t")], keybinds: [])

        XCTAssertFalse(assembled.map.values.contains(.newTab))
        XCTAssertEqual(assembled.unbound, [])
    }

    func test_unbindPlusABind_bindsAndIsNotUnbound() {
        let assembled = KeymapAssembler.assemble(
            floats: [],
            keybinds: [.unbind(.findNext), .bind(Chord(command: true, key: "9"), .findNext)])

        XCTAssertEqual(assembled.map[Chord(command: true, key: "9")], .findNext)
        XCTAssertEqual(assembled.unbound, [])
    }

    func test_unbindingAFloat_isRefused() {
        let live = KeymapAssembler.assemble(
            floats: [float(id: "x", key: "cmd+shift+j")], keybinds: [.unbind(.toggleToolFloat("x"))])
        XCTAssertEqual(live.map[Chord(command: true, shift: true, key: "j")], .toggleToolFloat("x"))
        XCTAssertEqual(live.unbound, [])

        let ghost = KeymapAssembler.assemble(floats: [], keybinds: [.unbind(.toggleToolFloat("ghost"))])
        XCTAssertEqual(ghost.unbound, [], "a float action must never reach the set the writer emits")
    }

    func test_unbindOnItsOwn_dropsOnlyThatActionsDefaults() {
        let assembled = KeymapAssembler.assemble(floats: [], keybinds: [.unbind(.increaseFontSize)])

        XCTAssertNil(assembled.map[Chord(command: true, key: "=")])
        XCTAssertNil(assembled.map[Chord(command: true, shift: true, key: "=")], "both defaults go")
        XCTAssertEqual(assembled.map[Chord(command: true, key: "-")], .decreaseFontSize)
        XCTAssertEqual(assembled.diagnostics, [])
    }

    func test_floatStealingActionsOnlyChord_reportsDiagnostic() {
        let assembled = KeymapAssembler.assemble(floats: [float(id: "x", key: "cmd+t")], keybinds: [])
        XCTAssertEqual(assembled.map[Chord(command: true, key: "t")], .toggleToolFloat("x"))
        XCTAssertFalse(assembled.map.values.contains(.newTab))
        XCTAssertEqual(assembled.diagnostics.count, 1)
        XCTAssertEqual(assembled.diagnostics.first?.scope, .keybind(.newTab))
        XCTAssertTrue(
            assembled.diagnostics.first!.message.contains("toggle_float:x"), assembled.diagnostics.first!.message)
        XCTAssertTrue(assembled.diagnostics.first!.message.contains("⌘T"), assembled.diagnostics.first!.message)
    }

    func test_userKeybindStealingAnotherActionsChord_reportsDiagnostic() {
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [KeybindParser.parse("toggle_zoom=cmd+d")!])
        XCTAssertEqual(assembled.diagnostics.map(\.scope), [.keybind(.splitVertical)])
    }

    func test_diagnostic_namesTheActionThatActuallyHoldsTheChord() {
        let assembled = KeymapAssembler.assemble(
            floats: [],
            keybinds: [
                KeybindParser.parse("toggle_zoom=cmd+d")!,
                KeybindParser.parse("new_window=cmd+d")!,
            ])
        XCTAssertEqual(assembled.map[Chord(command: true, key: "d")], .newWindow)
        let message = assembled.diagnostics.first { $0.scope == .keybind(.splitVertical) }?.message
        XCTAssertEqual(message, "⌘D goes to new_window.")
    }

    func test_displacementLeavingAnotherChord_isNotADiagnostic() {
        XCTAssertNil(
            KeymapDefaults.map[Chord(command: true, shift: true, key: "u")],
            "a default claimed the fixture's landing chord; move the fixture to a free one")
        let assembled = KeymapAssembler.assemble(
            floats: [],
            keybinds: [
                KeybindParser.parse("split_vertical=cmd+shift+u")!,
                KeybindParser.parse("toggle_zoom=cmd+d")!,
            ])
        XCTAssertEqual(assembled.map[Chord(command: true, shift: true, key: "u")], .splitVertical)
        XCTAssertEqual(assembled.diagnostics, [])
    }

    func test_cleanConfig_reportsNoDiagnostics() {
        XCTAssertEqual(KeymapAssembler.assemble(floats: [], keybinds: []).diagnostics, [])
    }

    private func usLayout(_ chord: Chord) -> Bool {
        let shiftedOnly: Set<String> = ["~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "|"]
        if !chord.shift, shiftedOnly.contains(chord.key) { return false }
        return true
    }

    func test_bindThatCantBeTyped_isIgnoredAndLeavesTheDefaultAlone() {
        let user = KeybindParser.parse("split_vertical=cmd+|")!
        let assembled = KeymapAssembler.assemble(floats: [], keybinds: [user], canType: usLayout)

        XCTAssertEqual(
            assembled.map[Chord(command: true, key: "d")], .splitVertical,
            "an unusable line must not cost the action its default")
        XCTAssertNil(assembled.map[Chord(command: true, key: "|")], "and the dead chord isn't bound")
        XCTAssertEqual(assembled.diagnostics.count, 1)
        let diagnostic = assembled.diagnostics[0]
        XCTAssertEqual(diagnostic.scope, .keybind(.splitVertical))
        XCTAssertTrue(diagnostic.headline.contains("unusable"), diagnostic.headline)
        XCTAssertTrue(diagnostic.message.contains("split_vertical=cmd+|"), diagnostic.message)
    }

    func test_sameBindOnALayoutThatCanTypeIt_isBoundWithNoComplaint() {
        let user = KeybindParser.parse("split_vertical=cmd+_")!
        let azerty: (Chord) -> Bool = { _ in true }
        let assembled = KeymapAssembler.assemble(floats: [], keybinds: [user], canType: azerty)

        XCTAssertEqual(assembled.map[Chord(command: true, key: "_")], .splitVertical)
        XCTAssertEqual(assembled.diagnostics, [])
    }

    func test_typeableBinds_areUnaffectedByTheCheck() {
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [KeybindParser.parse("new_tab=cmd+shift+opt+_")!], canType: usLayout)
        XCTAssertEqual(assembled.map[Chord(command: true, shift: true, option: true, key: "-")], .newTab)
        XCTAssertEqual(assembled.diagnostics, [])
    }
}
