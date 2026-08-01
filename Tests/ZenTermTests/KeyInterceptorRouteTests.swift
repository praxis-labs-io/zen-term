import AppKit
import XCTest

@testable import ZenTerm

/// The order `KeyInterceptor.route` resolves a keystroke in (ZEN-330). Getting it wrong is
/// invisible until it isn't: a mode placed above chord routing swallows ⌘T and pane nav for as
/// long as it's up, and one placed below the modifier fast-bail never sees a bare `j` at all,
/// which is every key scroll mode exists to claim.
final class KeyInterceptorRouteTests: XCTestCase {
    private func keyDown(_ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 0))
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
