import XCTest

@testable import ZenTerm

final class KeymapAssemblyTests: XCTestCase {
    private func float(id: String, key: String) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: "square.on.square", command: "run", dir: nil,
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
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "\\")], .splitVertical)
        XCTAssertEqual(map[Chord(command: true, option: true, key: "r")], .reloadConfig)
    }

    func test_splitHorizontal_isCmdShiftMinus_leavingBareCmdMinusFree() {
        // ZEN-142: bare ⌘- belongs to ghostty's text magnification, so the split moved off it.
        let map = assemble()
        XCTAssertEqual(map[Chord(command: true, shift: true, key: "-")], .splitHorizontal)
        XCTAssertNil(map[Chord(command: true, key: "-")])
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
}
