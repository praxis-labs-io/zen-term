import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

/// The load-time half of ZEN-10's three checks (ZEN-364).
///
/// `BackendShadowSweepTests` asks what libghostty is left holding at all, and that is a constant.
/// This asks what reaches it under whatever the user's config assembled to, which is not: a keybind
/// moves its action, `KeymapAssembler` drops that action's defaults, and the freed chord goes to
/// the backend. Nothing could see that before, because on a default install the chord in question
/// is still ours.
///
/// ZEN-365 emptied most of what this can find and ZEN-369 emptied the rest, so the report is quiet
/// on every config: the binds a rebind could expose were the ones held until ZenTerm named them,
/// and all of them are named. What is left is a regression guard, and the cases below keep the
/// chain that would report the next one honest.
@MainActor
final class BackendShadowTests: XCTestCase {
    override func tearDown() {
        KeyboardLayout.layoutOverrideForTesting = nil
        super.tearDown()
    }

    /// The keymap a config with `keybind = nav_up=ctrl+k` assembles to. Through the real assembler
    /// rather than a hand-built dictionary: dropping the rebound action's defaults is the step that
    /// frees the chord, so a stand-in map would test the arithmetic and not the behavior.
    private func keymapRebindingNavUp() -> [Chord: KeyInterceptor.ReservedChord] {
        keymapRebinding(.navUp, to: Chord(control: true, key: "k"))
    }

    /// Nav Up's default is ⌘⌥↑, and an arrow resolves off `Chord`'s keyCode table rather than the
    /// layout, so a case about a layout that cannot type a key needs an action whose default is a
    /// letter. Close Pane is one.
    private func keymapRebindingClosePane() -> [Chord: KeyInterceptor.ReservedChord] {
        keymapRebinding(.closePane, to: Chord(control: true, key: "w"))
    }

    private func keymapRebinding(
        _ action: KeyInterceptor.ReservedChord, to chord: Chord
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        KeymapAssembler.assemble(
            floats: [], keybinds: [.bind(chord, action)],
            canType: { _ in true }, protected: { [] }, menuOwner: { _ in nil }
        ).map
    }

    /// A probe that answers `d` to everything except the ⌥← canary, which it always claims.
    /// Every case below needs a live-looking backend, or `check` short-circuits to `.backendSilent`
    /// and the assertion under test never runs.
    private func probe(_ d: ChordDisposition) -> @MainActor (TerminalKey) -> ChordDisposition {
        let canary = BackendShadow.canary
        return { $0 == canary ? .claims : d }
    }

    // MARK: the backend has to be answering first

    /// The finding this whole gate exists for. `ghostty_surface_new` fails on a locked screen and
    /// leaves the surface object alive, so every chord reads `.ignores` and the check would report a
    /// clean config while never having asked anything.
    func test_aBackendThatAnswersNothingIsNotACleanConfig() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [40: "k", 17: "t"] }

        XCTAssertEqual(
            BackendShadow.check(assembled: keymapRebindingNavUp(), probe: { _ in .ignores }),
            .backendSilent)
    }

    /// The canary is the only chord that decides this, so it has to be one the running backend
    /// really holds. It was ⌘T until ZEN-365 unbound that, and the failure a canary we unbind
    /// produces is silent: every check reports a dead backend and nothing else changes. So this
    /// asks a real surface rather than a stub, and the next unbind that swallows it fails here.
    func test_theCanaryIsAChordTheRunningBackendStillHolds() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed (a locked screen does this)")

        XCTAssertNotEqual(
            surface.disposition(of: BackendShadow.canary), .ignores,
            "the liveness canary is unbound, so every shadow check now reports a dead backend")
    }

    // MARK: the freed set

    /// `t` is pinned alongside `k` so the assertion covers the set difference and not just the
    /// layout: ⌘T is a default the config left alone, and a check that skipped the difference would
    /// report it too.
    func test_aRebindHandsTheActionsOldChordToTheBackend() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [40: "k", 17: "t"] }

        let finding = BackendShadow.check(
            assembled: keymapRebindingNavUp(), probe: probe(.claims))

        guard case .freed(let freed) = finding else { return XCTFail("\(finding)") }
        XCTAssertEqual(Set(freed.map(\.chord)), [Chord(command: true, option: true, key: "↑")])
        XCTAssertTrue(freed.allSatisfy { $0.action == .navUp && $0.disposition == .claims })
    }

    /// The strong form: a probe that claims *everything* still finds nothing, because a config that
    /// rebinds nothing frees nothing. Without this the check could be reporting the whole keymap.
    func test_aConfigThatRebindsNothingHandsOverNothing() {
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [], canType: { _ in true }, protected: { [] },
            menuOwner: { _ in nil }
        ).map

        XCTAssertEqual(BackendShadow.check(assembled: assembled, probe: probe(.claims)), .freed([]))
    }

    /// A freed chord is only news if something down there takes it. Most are not: ⌘B is freed on a
    /// config that rebinds `toggle_bottom_drawer`, and nothing in libghostty binds it.
    func test_aFreedChordTheBackendIgnoresIsNotReported() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [40: "k", 17: "t"] }

        XCTAssertEqual(
            BackendShadow.check(assembled: keymapRebindingNavUp(), probe: probe(.ignores)),
            .freed([]))
    }

    /// A chord no key on this layout produces can't be handed to a backend as a keystroke, and
    /// nobody can press it either. The probe is never asked.
    func test_aFreedChordThisLayoutCannotTypeIsNotReported() {
        // No `w`, so ⌘W has nowhere to resolve to. The canary is an arrow and needs no layout.
        KeyboardLayout.layoutOverrideForTesting = { _ in [17: "t"] }

        XCTAssertEqual(
            BackendShadow.check(assembled: keymapRebindingClosePane(), probe: probe(.claims)),
            .freed([]))
    }

    // MARK: the line
    //
    // The line is this check's entire output. Nothing renders it, so nothing else would notice it
    // going wrong.

    func test_theLineNamesTheChordThatFellThroughAndTheOneTheActionMovedTo() {
        let freed = BackendShadow.FreedChord(
            chord: Chord(command: true, key: "k"), action: .navUp, disposition: .mayClaim)

        XCTAssertEqual(
            BackendShadow.line(for: freed, in: keymapRebindingNavUp()),
            "Keymap: nav_up moved to ctrl+k, so cmd+k now falls through. The backend takes it when "
                + "its own action applies, and otherwise lets it through.")
    }

    /// A later line can take the chord back off the action the user moved it to, leaving the action
    /// with nothing. Naming a chord it no longer holds would send someone to fix the wrong line.
    func test_theLineSaysSoWhenTheActionWasLeftWithNoChordAtAll() {
        let freed = BackendShadow.FreedChord(
            chord: Chord(command: true, key: "k"), action: .navUp, disposition: .claims)

        XCTAssertEqual(
            BackendShadow.line(for: freed, in: [:]),
            "Keymap: nav_up has no shortcut, so cmd+k now falls through. The backend takes it, so "
                + "it never reaches the program.")
    }

    // MARK: against the real backend

    /// The one that covers the whole chain: the assembler, the layout walk, the seam, and the C
    /// call. The stubbed cases above each cover one link and could all pass with the probe dead.
    ///
    /// **It expects nothing, and that is the finding.** ⌘K was the chord behind the whole effort:
    /// rebinding nav to `ctrl+hjkl` freed it, and libghostty answered `clear_screen`. ZEN-369 named
    /// that action and unbound libghostty's copy, and it was the last one. No chord a ZenTerm
    /// default holds is still bound down there, so a rebind now hands over a chord the program gets.
    ///
    /// So this reads as a regression guard rather than a demonstration. A ghostty pin bump that
    /// binds something under one of our defaults turns it red, which is the only way that would ever
    /// be noticed. The canary is what keeps an empty result from meaning a dead probe.
    func test_aRebindNowFreesNothingTheBackendStillTakes() throws {
        try XCTSkipUnless(
            KeyboardLayout.canType(Chord(command: true, key: "k")), "layout cannot type ⌘K")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed (a locked screen does this)")

        guard
            case .freed(let freed) = BackendShadow.check(
                assembled: keymapRebindingNavUp(), probe: surface.disposition)
        else { return XCTFail("the running backend answered nothing") }

        XCTAssertEqual(
            freed.map(\.chord.configToken), [],
            "libghostty binds a chord one of our defaults holds again. Either name the action or "
                + "add the trigger to GhosttyUnboundChords.triggers.")
    }
}
