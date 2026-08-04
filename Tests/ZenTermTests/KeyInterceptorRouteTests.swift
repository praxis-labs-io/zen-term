import AppKit
import XCTest

@testable import ZenTerm

/// The order `KeyInterceptor.route` resolves a keystroke in (ZEN-330). Getting it wrong is
/// invisible until it isn't: a mode placed above chord routing swallows ⌘T and pane nav for as
/// long as it's up, and one placed below the modifier fast-bail never sees a bare `j` at all,
/// which is every key scroll mode exists to claim.
final class KeyInterceptorRouteTests: XCTestCase {
    private func keyDown(
        _ characters: String, flags: NSEvent.ModifierFlags = [], isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: isARepeat, keyCode: 0))
    }

    /// An interceptor with one bound chord (⌘T), so a test can tell a reserved hit from a miss.
    private func interceptor() -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.setKeymap([Chord(command: true, key: "t"): .newTab])
        return keys
    }

    func test_aBareKeyReachesTheModeHandler() throws {
        let keys = interceptor()
        var seen: [String] = []
        keys.modeHandler = { event in
            seen.append(event.charactersIgnoringModifiers ?? "")
            return true
        }
        XCTAssertNil(keys.route(try keyDown("j")), "a claimed key must be consumed, not passed to the PTY")
        XCTAssertEqual(seen, ["j"])
    }

    func test_withNoModeTheSameKeyPassesThroughUntouched() throws {
        let keys = interceptor()
        let event = try keyDown("j")
        XCTAssertIdentical(keys.route(event), event)
    }

    func test_aKeyTheModeDeclinesStillReachesThePTY() throws {
        let keys = interceptor()
        keys.modeHandler = { _ in false }
        let event = try keyDown("x")
        XCTAssertIdentical(keys.route(event), event)
    }

    func test_aReservedChordFiresAndNeverReachesTheMode() throws {
        // The mode must not be able to brick the app's own chords while it's up.
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        var reachedMode = false
        keys.onReservedChord = { fired.append($0) }
        keys.modeHandler = { _ in
            reachedMode = true
            return true
        }
        XCTAssertNil(keys.route(try keyDown("t", flags: .command)))
        XCTAssertEqual(fired, [.newTab])
        XCTAssertFalse(reachedMode, "chord routing must win, so ⌘T still opens a tab in scroll mode")
    }

    /// ZEN-367's defaults sit on keys that type no character, and that is the shape of a keymap
    /// entry that looks right and never fires: `Chord.init`'s own comment names the trap. The
    /// event has to be the one macOS really sends, `.function` bit included, or the test proves
    /// nothing about ⌘Home. This drives `route`, which is the monitor's whole decision.
    func test_aKeyThatTypesNoCharacterStillFiresItsShippedDefault() throws {
        let keys = KeyInterceptor()  // the shipped defaults, not the one-chord stub
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 115, character: "\u{F729}")))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 119, character: "\u{F72B}")))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 116, character: "\u{F72C}")))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 121, character: "\u{F72D}")))

        XCTAssertEqual(fired, [.scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown])
    }

    /// Holding a page key keeps scrolling, and holding Home does not keep jumping to a top it is
    /// already at. A repeat the action declines is still consumed either way, so the difference is
    /// invisible except in what fires.
    func test_aHeldPageKeyRepeatsAndAHeldHomeKeyDoesNot() throws {
        let keys = KeyInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 121, character: "\u{F72D}", isARepeat: true)))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 115, character: "\u{F729}", isARepeat: true)))

        XCTAssertEqual(fired, [.scrollPageDown])
    }

    /// ⌘Home as AppKit delivers it: the private-use character, and `.function` alongside `.command`.
    /// A synthesized `.command`-only event is a keystroke macOS never sends.
    private func functionKeyDown(keyCode: UInt16, character: String, isARepeat: Bool = false) throws
        -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .function], timestamp: 0,
                windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: isARepeat, keyCode: keyCode))
    }

    func test_anUnboundModifiedKeyFallsToTheMode() throws {
        // ⌃d is not a chord anyone can reserve (it's terminal EOF), so it reaches the mode only
        // because the fast-bail hands misses on rather than returning early.
        let keys = interceptor()
        var seen = false
        keys.modeHandler = { _ in
            seen = true
            return true
        }
        XCTAssertNil(keys.route(try keyDown("d", flags: .control)))
        XCTAssertTrue(seen)
    }

    func test_aChordTheGuardVetoedGoesToTheTerminalNotTheMode() throws {
        // The veto's contract is that the PROGRAM receives the real key (⌃j inside nvim). Letting
        // a vetoed chord fall to a sticky mode means neither the chrome nor the program acts on
        // it, so the key does nothing at all over an nvim pane while doing something over any
        // other pane.
        let keys = KeyInterceptor()
        keys.setKeymap([Chord(control: true, key: "j"): .navDown])
        keys.passThroughGuard = { _, _ in true }
        var fired: [KeyInterceptor.ReservedChord] = []
        var reachedMode = false
        keys.onReservedChord = { fired.append($0) }
        keys.modeHandler = { _ in
            reachedMode = true
            return true
        }

        let event = try keyDown("j", flags: .control)
        XCTAssertIdentical(keys.route(event), event)
        XCTAssertEqual(fired, [], "the guard vetoed it, so the chrome must not act either")
        XCTAssertFalse(reachedMode, "and the mode must not eat what was handed to the program")
    }

    func test_anUnvetoedMissStillReachesTheMode() throws {
        // The mirror of the case above: nothing claimed the chord, so the mode may have it.
        let keys = interceptor()
        keys.passThroughGuard = { _, _ in true }  // never consulted; ⌃d hits no keymap entry
        var reachedMode = false
        keys.modeHandler = { _ in
            reachedMode = true
            return true
        }

        XCTAssertNil(keys.route(try keyDown("d", flags: .control)))
        XCTAssertTrue(reachedMode)
    }

    func test_captureBeatsTheModeEntirely() throws {
        // Recording a keybind in Settings must capture the literal keystroke, mode or not.
        let keys = interceptor()
        var captured = 0
        var reachedMode = false
        keys.modeHandler = { _ in
            reachedMode = true
            return true
        }
        keys.beginCapture { _ in captured += 1 }
        XCTAssertNil(keys.route(try keyDown("j")))
        XCTAssertEqual(captured, 1)
        XCTAssertFalse(reachedMode)
    }

    // MARK: Auto-repeat

    /// Auto-repeat is the silently-destructive kind: nothing looks wrong, the app just does the
    /// thing thirty times. `route` read no `isARepeat` at all, so leaning on ⌘N opened windows
    /// until the key came up.
    func test_aHeldChordWhoseActionDoesNotRepeatFiresOnce() throws {
        let keys = interceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try keyDown("t", flags: .command)))
        XCTAssertNil(
            keys.route(try keyDown("t", flags: .command, isARepeat: true)),
            "the chord is still ours while it is held, so the raw ⌘T must not fall to the program")
        XCTAssertNil(keys.route(try keyDown("t", flags: .command, isARepeat: true)))

        XCTAssertEqual(fired, [.newTab], "a held ⌘T opens one tab, not one per repeat")
    }

    /// The other half. Nav, resize and font size accumulate toward something the eye tracks, and
    /// each runs out of room on its own, so a hold is the point rather than the bug.
    func test_aHeldChordWhoseActionRepeatsFiresOnEveryRepeat() throws {
        let keys = KeyInterceptor()
        keys.setKeymap([Chord(command: true, key: "h"): .navLeft])
        var fired = 0
        keys.onReservedChord = { _ in fired += 1 }

        _ = keys.route(try keyDown("h", flags: .command))
        _ = keys.route(try keyDown("h", flags: .command, isARepeat: true))
        _ = keys.route(try keyDown("h", flags: .command, isARepeat: true))

        XCTAssertEqual(fired, 3, "holding pane-nav keeps walking; it stops at the edge pane")
    }

    /// A repeat the guard handed to the program is the program's, repeat or not. Holding `ctrl+h`
    /// in nvim is how you walk a buffer.
    func test_aVetoedChordStillRepeatsIntoTheProgram() throws {
        let keys = KeyInterceptor()
        keys.setKeymap([Chord(control: true, key: "h"): .navLeft])
        keys.passThroughGuard = { _, _ in true }

        let event = try keyDown("h", flags: .control, isARepeat: true)
        XCTAssertIdentical(keys.route(event), event)
    }

    func test_flagsChangedNeverReachesTheMode() throws {
        // A bare ⇧ press is not a scroll key. Routing it would fire the decoder on every modifier.
        let keys = interceptor()
        var reachedMode = false
        keys.modeHandler = { _ in
            reachedMode = true
            return true
        }
        let flags = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 56))
        XCTAssertIdentical(keys.route(flags), flags)
        XCTAssertFalse(reachedMode)
    }
}
