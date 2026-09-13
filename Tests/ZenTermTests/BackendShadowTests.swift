import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

@MainActor
final class BackendShadowTests: XCTestCase {
    override func tearDown() {
        KeyboardLayout.layoutOverrideForTesting = nil
        super.tearDown()
    }

    private func keymapRebindingNavUp() -> [Chord: KeyInterceptor.ReservedChord] {
        keymapRebinding(.navUp, to: Chord(control: true, key: "k"))
    }

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

    private func probe(_ d: ChordDisposition) -> @MainActor (TerminalKey) -> ChordDisposition {
        let canary = BackendShadow.canary
        return { $0 == canary ? .claims : d }
    }

    func test_aBackendThatAnswersNothingIsNotACleanConfig() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [40: "k", 17: "t"] }

        XCTAssertEqual(
            BackendShadow.check(assembled: keymapRebindingNavUp(), probe: { _ in .ignores }),
            .backendSilent)
    }

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

    func test_aRebindHandsTheActionsOldChordToTheBackend() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [40: "k", 17: "t"] }

        let finding = BackendShadow.check(
            assembled: keymapRebindingNavUp(), probe: probe(.claims))

        guard case .freed(let freed) = finding else { return XCTFail("\(finding)") }
        XCTAssertEqual(Set(freed.map(\.chord)), [Chord(command: true, option: true, key: "↑")])
        XCTAssertTrue(freed.allSatisfy { $0.action == .navUp && $0.disposition == .claims })
    }

    func test_aConfigThatRebindsNothingHandsOverNothing() {
        let assembled = KeymapAssembler.assemble(
            floats: [], keybinds: [], canType: { _ in true }, protected: { [] },
            menuOwner: { _ in nil }
        ).map

        XCTAssertEqual(BackendShadow.check(assembled: assembled, probe: probe(.claims)), .freed([]))
    }

    func test_aFreedChordTheBackendIgnoresIsNotReported() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [40: "k", 17: "t"] }

        XCTAssertEqual(
            BackendShadow.check(assembled: keymapRebindingNavUp(), probe: probe(.ignores)),
            .freed([]))
    }

    func test_aFreedChordThisLayoutCannotTypeIsNotReported() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [17: "t"] }

        XCTAssertEqual(
            BackendShadow.check(assembled: keymapRebindingClosePane(), probe: probe(.claims)),
            .freed([]))
    }

    func test_theLineNamesTheChordThatFellThroughAndTheOneTheActionMovedTo() {
        let freed = BackendShadow.FreedChord(
            chord: Chord(command: true, key: "k"), action: .navUp, disposition: .mayClaim)

        XCTAssertEqual(
            BackendShadow.line(for: freed, in: keymapRebindingNavUp()),
            "Keymap: nav_up moved to ctrl+k, so cmd+k now falls through. The backend takes it when "
                + "its own action applies, and otherwise lets it through.")
    }

    func test_theLineSaysSoWhenTheActionWasLeftWithNoChordAtAll() {
        let freed = BackendShadow.FreedChord(
            chord: Chord(command: true, key: "k"), action: .navUp, disposition: .claims)

        XCTAssertEqual(
            BackendShadow.line(for: freed, in: [:]),
            "Keymap: nav_up has no shortcut, so cmd+k now falls through. The backend takes it, so "
                + "it never reaches the program.")
    }

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
