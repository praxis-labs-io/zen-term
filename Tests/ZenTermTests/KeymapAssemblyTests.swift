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
        floats: [ToolFloat] = [], keybinds: [KeybindParser.Line] = []
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        KeymapAssembler.assemble(floats: floats, keybinds: keybinds).map
    }

    /// `toolbar:false` only hides the toolbar button — the chord must still bind, or hiding a
    /// button would quietly cost the tool its shortcut (the liveness contract).
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

    /// Each chord asserted at its home and absent from the one it left. A stale default nobody
    /// removed keeps firing alongside the new one, which reads as the new chord working.
    func test_theMovedChords_areOnlyAtTheirNewHomes() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "d")], .splitHorizontal)
        XCTAssertEqual(map[Chord(command: true, key: "g")], .openDiffViewer)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "⏎")], .toggleZoom)
        XCTAssertEqual(map[Chord(command: true, key: "p")], .toggleRepoPicker)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "p")], .toggleCommandPalette)

        XCTAssertNil(map[Chord(command: true, shift: true, key: "\\")], "⌘⇧\\ retired with the split")
        XCTAssertNil(map[Chord(command: true, shift: true, key: "-")], "and so did ⌘⇧-")
        XCTAssertNil(map[Chord(command: true, shift: true, key: "f")], "⌘⇧F retired with Fill Screen")
        XCTAssertEqual(map[Chord(command: true, key: "-")], .decreaseFontSize, "⌘- was never a split")
    }

    /// Pane nav and resize on ghostty's arrows, and nothing beside them. A second spelling of a
    /// directional action is invisible until a Shortcuts row picks the wrong one of the two to
    /// advertise.
    func test_paneDirectionals_areOnGhosttysArrowsAlone() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, option: true, key: "↑")], .navUp)
        XCTAssertEqual(map[Chord(command: true, control: true, key: "←")], .resizeLeft)

        XCTAssertNil(map[Chord(command: true, shift: true, key: "h")], "⌘⇧hjkl resize retired")
        XCTAssertNotEqual(map[Chord(command: true, key: "k")], .navUp, "and ⌘hjkl nav with it")
    }

    /// The three screen actions on ghostty's own chords. Each is reachable from the palette either
    /// way, so a missing default here is invisible from anywhere else in the suite.
    func test_theScreenActions_tookTheChordsNavAndResizeGaveUp() {
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, key: "k")], .clearScreen)
        XCTAssertEqual(map[Chord(command: true, key: "j")], .scrollToSelection)
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "j")], .writeScreenFile)
    }

    /// Select All ships no chord: Edit > Select All holds ⌘A, and it has to, because
    /// `KeyInterceptor` resolves ahead of the responder chain: a default here would take the chord
    /// off every text field in the app. The action stays, for a config that rebinds it.
    func test_selectAll_shipsNoChord() {
        let map = assemble()
        XCTAssertNil(map[Chord(command: true, key: "a")], "⌘A is the Edit menu's")
        XCTAssertEqual(map.filter { $0.value == .selectAll }, [:])
    }

    /// Stepping a search is `n` and `N` while the search holds the keyboard, not a chord, so both
    /// actions ship without one and ⌘G is the diff viewer's.
    func test_findStepping_holdsNoChord() {
        let map = assemble()
        XCTAssertEqual(map.filter { $0.value == .findNext }, [:])
        XCTAssertEqual(map.filter { $0.value == .findPrevious }, [:])
        XCTAssertEqual(map[Chord(command: true, key: "g")], .openDiffViewer)
    }

    /// The chords that would be a second spelling of something already bound. ghostty's is the one
    /// that ships in each pair.
    func test_theRemainingDuplicates_areGone() {
        let map = assemble()
        XCTAssertNil(map[Chord(control: true, key: "⇥")], "⌃⇥ tab cycling, ⌘] is the default")
        XCTAssertNil(map[Chord(shift: true, control: true, key: "⇥")], "and ⌃⇧⇥")
        XCTAssertNil(map[Chord(command: true, control: true, key: "f")], "⌃⌘F fill screen, ⌘⏎ is it")
        XCTAssertNil(map[Chord(command: true, key: "/")], "⌘/ find, ⌘F is it")
        XCTAssertNil(map[Chord(command: true, option: true, key: "r")], "⌘⌥R reload, ⌘⇧, is it")
    }

    /// The rule the tests above are each one case of. Increase is the sole exception, and it is a
    /// layout artifact rather than a second way to spell the action: ⌘+ *is* ⌘⇧= on a US keyboard.
    func test_everyActionShipsOneChord_exceptIncrease() {
        var counts: [KeyInterceptor.ReservedChord: Int] = [:]
        for action in assemble().values { counts[action, default: 0] += 1 }
        XCTAssertEqual(
            counts.filter { $0.value > 1 }.map(\.key), [.increaseFontSize],
            "a second default chord needs a reason at the call site, and a line in this test")
    }

    /// ⌘+ is physically ⌘⇧= on a US layout, and `Chord` folds the "+" onto "=" because Shift is set.
    /// Both spellings have to reach increase: binding ⌘= alone leaves the keypress most people make
    /// falling through to libghostty, which still binds it per surface.
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
        let map = assemble(keybinds: [.bind(Chord(command: true, option: true, key: "="), .increaseFontSize)])
        XCTAssertEqual(map[Chord(command: true, option: true, key: "=")], .increaseFontSize)
        XCTAssertNil(map[Chord(command: true, key: "=")])
        XCTAssertNil(map[Chord(command: true, shift: true, key: "=")])
    }

    func test_theShiftedSymbolDefault_holdsOneEntryNotTwo() {
        // Canonicalization replaced hand-listed sibling spellings with a single entry. The "+"
        // lookup still resolves — it canonicalizes onto "=" because Shift is set — but it's the SAME
        // entry, not a second one, which is what makes narrowing and conflict reporting honest.
        //
        // ⌘⇧= is the last shipped default spelled with a shifted symbol, since the splits moved
        // off ⌘⇧\ and ⌘⇧-. So increase holds exactly its two written chords and no third.
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "+")], .increaseFontSize)
        XCTAssertEqual(map.filter { $0.value == .increaseFontSize }.count, 2)
    }

    func test_floatChord_overridesBuiltin() {
        // A float claiming ⌘F displaces the built-in .toggleSearch.
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
        // Rebinding new_tab to ⌘Y must release its default ⌘T, not leave both bound.
        let map = assemble(keybinds: [.bind(Chord(command: true, key: "y"), .newTab)])
        XCTAssertEqual(map[Chord(command: true, key: "y")], .newTab)
        XCTAssertNil(map[Chord(command: true, key: "t")])  // old default freed
    }

    func test_rebindingShiftedSymbol_landsOnOneCanonicalChord() {
        // The trap that sank the first attempt: a config written `cmd+shift+-` parses to
        // the base "-", but a live ⌘⇧- press decodes to "_". Both spellings canonicalize, so one
        // entry serves both — no sibling expansion, and no way to write a dead bind.
        let map = assemble(keybinds: [KeybindParser.parse("split_vertical=cmd+shift+-")!])
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitVertical)  // written form
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "_")], .splitVertical)  // live-event form
        XCTAssertEqual(map.filter { $0.value == .splitVertical }.count, 1)
    }

    func test_lastKeybindWins() {
        let chord = Chord(command: true, key: "f")
        let map = assemble(keybinds: [.bind(chord, .toggleBottomDrawer), .bind(chord, .toggleRightDrawer)])
        XCTAssertEqual(map[chord], .toggleRightDrawer)
    }

    func test_toggleFloatKeybind_forUnknownID_isDropped() {
        let map = assemble(keybinds: [.bind(Chord(command: true, key: "y"), .toggleToolFloat("ghost"))])
        XCTAssertNil(map[Chord(command: true, key: "y")])  // no such float → not bound
    }

    // MARK: the built-in Scratch float

    func test_scratchShipsOnCmdSemicolon() {
        XCTAssertEqual(assemble()[Chord(command: true, key: ";")], .toggleToolFloat("scratch"))
    }

    /// `assemble` is handed the floats the CONFIG parsed, which never include the built-in. Read
    /// `floatIDs` off that list alone and this line dies as naming no float.
    func test_scratchKeybind_isNotDroppedWithNoConfiguredFloats() {
        let map = assemble(
            floats: [], keybinds: [.bind(Chord(command: true, key: "y"), .toggleToolFloat("scratch"))])

        XCTAssertEqual(map[Chord(command: true, key: "y")], .toggleToolFloat("scratch"))
        XCTAssertNil(map[Chord(command: true, key: ";")], "a rebind moves it, leaving the default free")
    }

    /// The mirror of `test_unbindingAFloat_isRefused`. The built-in's chord is a default, so
    /// dropping it is real: the refusal exists for chords a `float =` line puts back.
    func test_unbindingScratch_isHonored() {
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [.unbind(.toggleToolFloat("scratch"))])

        XCTAssertNil(assembled.map[Chord(command: true, key: ";")])
        XCTAssertEqual(assembled.unbound, [.toggleToolFloat("scratch")])
        XCTAssertEqual(assembled.diagnostics, [], "a config written on purpose says nothing")
    }

    /// A user float taking ⌘; leaves the built-in chordless. It has no Tools row, so the problem
    /// has to land on its Shortcuts row or it has nowhere to render.
    func test_userFloatTakingScratchsChord_reportsItAgainstScratch() {
        let assembled = KeymapAssembler.assemble(
            floats: [float(id: "x", key: "cmd+;")], keybinds: [])

        XCTAssertEqual(assembled.map[Chord(command: true, key: ";")], .toggleToolFloat("x"))
        XCTAssertEqual(assembled.diagnostics.count, 1)
        XCTAssertEqual(assembled.diagnostics.first?.scope, .keybind(.toggleToolFloat("scratch")))
    }

    /// Both answers work for the built-in, unlike a user float's, which can offer neither.
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

    // MARK: unbinding

    /// The whole point of the feature. A float on ⌘G takes the diff viewer's only chord, which
    /// warns at every launch with no way to say "yes, I meant that". The `= none` line is that way,
    /// and the silence is the assertion: a config the user wrote on purpose must not tell them off.
    func test_unbindLine_leavesTheActionChordless_andSaysNothing() {
        let assembled = KeymapAssembler.assemble(
            floats: [float(id: "x", key: "cmd+g")], keybinds: [.unbind(.openDiffViewer)])

        XCTAssertEqual(assembled.map[Chord(command: true, key: "g")], .toggleToolFloat("x"))
        XCTAssertFalse(assembled.map.values.contains(.openDiffViewer))
        XCTAssertEqual(assembled.diagnostics, [], "an unbind the user asked for is not a problem")
        XCTAssertEqual(assembled.unbound, [.openDiffViewer])
    }

    /// The same config without the line, so the silence above is the line's doing and not the
    /// float's. The assembler records the fact either way, since the Shortcuts row renders it.
    /// Only the unbind keeps it out of `unbound`, which is what the writer emits from.
    func test_theSameCollisionWithoutTheLine_stillRecordsTheFact() {
        let assembled = KeymapAssembler.assemble(floats: [float(id: "x", key: "cmd+g")], keybinds: [])

        XCTAssertEqual(assembled.diagnostics.map(\.scope), [.keybind(.openDiffViewer)])
        XCTAssertEqual(assembled.unbound, [], "a displacement is not an intentional unbind")
    }

    /// `unbound` feeds the writer, so an action left chordless by a collision must stay out of it.
    /// In it, the next Settings write would put `= none` on disk and turn a reported conflict into
    /// a silent one the user never agreed to.
    func test_displacementLeavingNothing_isNotReportedAsUnbound() {
        let assembled = KeymapAssembler.assemble(floats: [float(id: "x", key: "cmd+t")], keybinds: [])

        XCTAssertFalse(assembled.map.values.contains(.newTab))
        XCTAssertEqual(assembled.unbound, [])
    }

    /// A file holding both a `none` and a real bind for one action is a contradiction, and the bind
    /// wins. Reporting it as unbound too would have the writer emit both lines back, so the file
    /// keeps contradicting itself forever.
    func test_unbindPlusABind_bindsAndIsNotUnbound() {
        let assembled = KeymapAssembler.assemble(
            floats: [],
            keybinds: [.unbind(.findNext), .bind(Chord(command: true, key: "9"), .findNext)])

        XCTAssertEqual(assembled.map[Chord(command: true, key: "9")], .findNext)
        XCTAssertEqual(assembled.unbound, [])
    }

    /// A float's chord is the `key:` on its own line, and `key:` is required, so unbinding one this
    /// way could only ever be a no-op: the float rebinds the chord a few lines later. It is refused
    /// where the unknown-float-id line is refused, and logged the same way.
    ///
    /// The id that names no float is what the refusal is actually load-bearing for. Accepted, it
    /// would land in `unbound`, and from there the writer emits `toggle_float:ghost=none` forever
    /// while the Shortcuts card carries a float action in a set that holds none.
    func test_unbindingAFloat_isRefused() {
        let live = KeymapAssembler.assemble(
            floats: [float(id: "x", key: "cmd+shift+j")], keybinds: [.unbind(.toggleToolFloat("x"))])
        XCTAssertEqual(live.map[Chord(command: true, shift: true, key: "j")], .toggleToolFloat("x"))
        XCTAssertEqual(live.unbound, [])

        let ghost = KeymapAssembler.assemble(floats: [], keybinds: [.unbind(.toggleToolFloat("ghost"))])
        XCTAssertEqual(ghost.unbound, [], "a float action must never reach the set the writer emits")
    }

    /// An unbind of an action nothing else touches: no chord, no complaint, and the rest of the
    /// defaults untouched.
    func test_unbindOnItsOwn_dropsOnlyThatActionsDefaults() {
        let assembled = KeymapAssembler.assemble(floats: [], keybinds: [.unbind(.increaseFontSize)])

        XCTAssertNil(assembled.map[Chord(command: true, key: "=")])
        XCTAssertNil(assembled.map[Chord(command: true, shift: true, key: "=")], "both defaults go")
        XCTAssertEqual(assembled.map[Chord(command: true, key: "-")], .decreaseFontSize)
        XCTAssertEqual(assembled.diagnostics, [])
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
            floats: [], keybinds: [KeybindParser.parse("toggle_zoom=cmd+d")!])
        XCTAssertEqual(assembled.diagnostics.map(\.scope), [.keybind(.splitVertical)])
    }

    func test_diagnostic_namesTheActionThatActuallyHoldsTheChord() {
        // Two lines claim ⌘D; last wins, so new_window ends up holding it. The message tells the
        // user which config line to go edit — naming toggle_zoom (which merely passed through on the
        // way) would send them to fix a line that no longer has the chord.
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
        // toggle_zoom takes split_vertical's ⌘D, and the same config gives split_vertical ⌘⇧U
        // instead: a deliberate reshuffle, not a hole. Warning here would cry wolf.
        //
        // Both fixture chords have to be ones no default holds, or the reshuffle displaces a third
        // action and the diagnostic this asserts is absent shows up for a real reason. The landing
        // chord was ⌘⇧V until that became paste_selection.
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
            assembled.map[Chord(command: true, key: "d")], .splitVertical,
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
