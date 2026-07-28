import XCTest

@testable import ZenTerm

final class KeymapAssemblyTests: XCTestCase {
    private func float(id: String, key: String) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: "square.on.square", command: "run", dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord.parse(key)!)
    }

    /// The resolved map alone — most tests don't care about diagnostics.
    private func assemble(
        floats: [ToolFloat] = [], keybinds: [(Chord, KeyInterceptor.ReservedChord)] = []
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        KeymapAssembler.assemble(floats: floats, keybinds: keybinds).map
    }

    func test_defaultsPresent() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "f")], .toggleZoom)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "f")], .fillScreen)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "\\")], .splitVertical)
        XCTAssertEqual(map[Chord(command: true, option: true, key: "r")], .reloadConfig)
    }

    func test_splitHorizontal_isCmdShiftMinus_notBareCmdMinus() {
        // ZEN-142 moved the split off bare ⌘- to leave it to libghostty's own text magnification.
        // ZEN-224 took that chord over for app-wide font size, so ⌘- is bound again — but to
        // decrease, never to split. Getting these two confused resizes the terminal on a split.
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitHorizontal)
        XCTAssertEqual(map[Chord(command: true, key: "-")], .decreaseFontSize)
    }

    /// ⌘+ is physically ⌘⇧= on a US layout, and `Chord` folds the "+" onto "=" because Shift is set.
    /// Both spellings have to reach increase: binding ⌘= alone leaves the keypress most people make
    /// falling through to libghostty, which still binds it per surface — ZEN-224 all over again.
    func test_bothIncreaseChords_areBound() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "=")], .increaseFontSize)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "=")], .increaseFontSize)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "+")], .increaseFontSize)  // folds
        XCTAssertEqual(map[Chord(command: true, key: "0")], .resetFontSize)
    }

    /// ⌘0 is font-size reset, and the tab-select family stops at ⌘1. A `for n in 0...9` slip would
    /// silently shadow one of the two.
    func test_selectTab_doesNotClaimCmdZero() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "1")], .selectTab(1))
        XCTAssertEqual(map[Chord(command: true, key: "0")], .resetFontSize)
    }

    /// Increase is the one action shipping two default chords. A rebind has to free *both*, or the
    /// old ⌘+ keeps firing alongside the new chord.
    func test_rebindingIncrease_freesBothDefaultChords() {
        let map = assemble(keybinds: [(Chord(command: true, option: true, key: "="), .increaseFontSize)])
        XCTAssertEqual(map[Chord(command: true, option: true, key: "=")], .increaseFontSize)
        XCTAssertNil(map[Chord(command: true, key: "=")])
        XCTAssertNil(map[Chord(command: true, shift: true, key: "=")])
    }

    func test_shiftedSymbolDefaults_holdExactlyOneEntryEach() {
        // Canonicalization replaced the hand-listed "|"/"\\" pair with a single entry. The "|"
        // lookup still resolves — it canonicalizes to the same chord — but it's the SAME entry,
        // not a second one, which is what makes narrowing and conflict reporting honest.
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "|")], .splitVertical)
        XCTAssertEqual(map.filter { $0.value == .splitVertical }.count, 1)
        XCTAssertEqual(map.filter { $0.value == .splitHorizontal }.count, 1)
    }

    func test_floatChord_overridesBuiltin() {
        // A float claiming ⌘F displaces the built-in .toggleZoom.
        let map = assemble(floats: [float(id: "x", key: "cmd+f")])
        XCTAssertEqual(map[Chord(command: true, key: "f")], .toggleToolFloat("x"))
    }

    func test_userKeybind_overridesFloatChord() {
        let map = assemble(
            floats: [float(id: "x", key: "cmd+shift+l")],
            keybinds: [(Chord(command: true, shift: true, key: "l"), .toggleZoom)])
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "l")], .toggleZoom)
    }

    func test_rebind_freesActionsDefaultChord() {
        // Rebinding new_tab to ⌘Y must release its default ⌘T, not leave both bound.
        let map = assemble(keybinds: [(Chord(command: true, key: "y"), .newTab)])
        XCTAssertEqual(map[Chord(command: true, key: "y")], .newTab)
        XCTAssertNil(map[Chord(command: true, key: "t")])  // old default freed
    }

    func test_rebindingShiftedSymbol_landsOnOneCanonicalChord() {
        // The trap that sank the first attempt at ZEN-142: a config written `cmd+shift+-` parses to
        // the base "-", but a live ⌘⇧- press decodes to "_". Both spellings canonicalize, so one
        // entry serves both — no sibling expansion, and no way to write a dead bind.
        let map = assemble(keybinds: [KeybindParser.parse("split_vertical=cmd+shift+-")!])
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitVertical)  // written form
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "_")], .splitVertical)  // live-event form
        XCTAssertEqual(map.filter { $0.value == .splitVertical }.count, 1)
    }

    func test_lastKeybindWins() {
        let chord = Chord(command: true, key: "f")
        let map = assemble(keybinds: [(chord, .toggleBottomDrawer), (chord, .toggleRightDrawer)])
        XCTAssertEqual(map[chord], .toggleRightDrawer)
    }

    func test_toggleFloatKeybind_forUnknownID_isDropped() {
        let map = assemble(keybinds: [(Chord(command: true, key: "y"), .toggleToolFloat("ghost"))])
        XCTAssertNil(map[Chord(command: true, key: "y")])  // no such float → not bound
    }

    // MARK: diagnostics

    func test_floatStealingActionsOnlyChord_reportsDiagnostic() {
        // A float on ⌘T takes new_tab's only chord. Silent today; the Keybinds row needs to say why.
        let assembled = KeymapAssembler.assemble(floats: [float(id: "x", key: "cmd+t")], keybinds: [])
        XCTAssertEqual(assembled.map[Chord(command: true, key: "t")], .toggleToolFloat("x"))
        XCTAssertFalse(assembled.map.values.contains(.newTab))  // left with no chord at all
        XCTAssertEqual(assembled.diagnostics.count, 1)
        XCTAssertEqual(assembled.diagnostics.first?.scope, .keybind(.newTab))
        // Names the config token to grep for, not the UI title.
        XCTAssertTrue(
            assembled.diagnostics.first!.message.contains("toggle_float:x"), assembled.diagnostics.first!.message)
        XCTAssertTrue(assembled.diagnostics.first!.message.contains("⌘T"), assembled.diagnostics.first!.message)
    }

    func test_userKeybindStealingAnotherActionsChord_reportsDiagnostic() {
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [KeybindParser.parse("toggle_zoom=cmd+shift+\\")!])
        XCTAssertEqual(assembled.diagnostics.map(\.scope), [.keybind(.splitVertical)])
    }

    func test_diagnostic_namesTheActionThatActuallyHoldsTheChord() {
        // Two lines claim ⌘⇧\; last wins, so new_window ends up holding it. The message tells the
        // user which config line to go edit — naming toggle_zoom (which merely passed through on the
        // way) would send them to fix a line that no longer has the chord.
        let assembled = KeymapAssembler.assemble(
            floats: [],
            keybinds: [
                KeybindParser.parse("toggle_zoom=cmd+shift+\\")!,
                KeybindParser.parse("new_window=cmd+shift+\\")!,
            ])
        XCTAssertEqual(assembled.map[Chord(command: true, shift: true, key: "\\")], .newWindow)
        let message = assembled.diagnostics.first { $0.scope == .keybind(.splitVertical) }?.message
        XCTAssertEqual(message, "⌘⇧\\ went to new_window in your config.")
    }

    func test_displacementLeavingAnotherChord_isNotADiagnostic() {
        // toggle_zoom takes split_vertical's ⌘⇧\, but the same config gives split_vertical ⌘⇧V —
        // a deliberate reshuffle, not a hole. Warning here would cry wolf.
        let assembled = KeymapAssembler.assemble(
            floats: [],
            keybinds: [
                KeybindParser.parse("split_vertical=cmd+shift+v")!,
                KeybindParser.parse("toggle_zoom=cmd+shift+\\")!,
            ])
        XCTAssertEqual(assembled.map[Chord(command: true, shift: true, key: "v")], .splitVertical)
        XCTAssertEqual(assembled.diagnostics, [])
    }

    func test_cleanConfig_reportsNoDiagnostics() {
        XCTAssertEqual(KeymapAssembler.assemble(floats: [], keybinds: []).diagnostics, [])
    }

    // MARK: un-typeable binds
    //
    // The layout is stated, never inherited from whatever keyboard the test machine has — the whole
    // point of the check is that the answer differs per layout.

    /// A US layout: the shifted symbols need Shift; nothing produces them without it.
    private func usLayout(_ chord: Chord) -> Bool {
        let shiftedOnly: Set<String> = ["~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "|"]
        if !chord.shift, shiftedOnly.contains(chord.key) { return false }
        return true
    }

    func test_bindThatCantBeTyped_isIgnoredAndLeavesTheDefaultAlone() {
        // `cmd+|` is un-typeable on US — `|` needs Shift. Binding it anyway gave split_vertical a
        // chord no keypress could produce AND stripped its default, leaving it with nothing.
        let user = KeybindParser.parse("split_vertical=cmd+|")!
        let assembled = KeymapAssembler.assemble(floats: [], keybinds: [user], canType: usLayout)

        XCTAssertEqual(
            assembled.map[Chord(command: true, shift: true, key: "\\")], .splitVertical,
            "an unusable line must not cost the action its default")
        XCTAssertNil(assembled.map[Chord(command: true, key: "|")], "and the dead chord isn't bound")
        XCTAssertEqual(assembled.diagnostics.count, 1)
        let diagnostic = assembled.diagnostics[0]
        XCTAssertEqual(diagnostic.scope, .keybind(.splitVertical))
        // A different claim from "has no shortcut" — the action still has its default.
        XCTAssertTrue(diagnostic.headline.contains("unusable"), diagnostic.headline)
        XCTAssertTrue(diagnostic.message.contains("split_vertical=cmd+|"), diagnostic.message)
    }

    func test_sameBindOnALayoutThatCanTypeIt_isBoundWithNoComplaint() {
        // The same spec on AZERTY, where `_` is unshifted: perfectly usable, and warning about it
        // would be slander. This is why the check asks the layout instead of guessing from the glyph.
        let user = KeybindParser.parse("split_vertical=cmd+_")!
        let azerty: (Chord) -> Bool = { _ in true }
        let assembled = KeymapAssembler.assemble(floats: [], keybinds: [user], canType: azerty)

        XCTAssertEqual(assembled.map[Chord(command: true, key: "_")], .splitVertical)
        XCTAssertEqual(assembled.diagnostics, [])
    }

    func test_typeableBinds_areUnaffectedByTheCheck() {
        // A shifted symbol on an unclaimed chord: typeable on US, so it binds and says nothing.
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [KeybindParser.parse("new_tab=cmd+shift+opt+_")!], canType: usLayout)
        XCTAssertEqual(assembled.map[Chord(command: true, shift: true, option: true, key: "-")], .newTab)
        XCTAssertEqual(assembled.diagnostics, [])
    }
}
