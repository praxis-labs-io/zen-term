import AppKit
import XCTest

@testable import ZenTerm

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

    private func interceptor() -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.setKeymap([Chord(command: true, key: "t"): .newTab])
        return keys
    }

    private func commandDown() throws -> NSEvent {
        let sided = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICELCMDKEYMASK))
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: sided, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 0x37))
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

    func test_aKeyThatTypesNoCharacterStillFiresItsShippedDefault() throws {
        let keys = KeyInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 115, character: "\u{F729}")))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 119, character: "\u{F72B}")))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 116, character: "\u{F72C}")))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 121, character: "\u{F72D}")))

        XCTAssertEqual(fired, [.scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown])
    }

    func test_aUserBoundCtrlTab_fires() throws {
        let keys = KeyInterceptor()
        keys.setKeymap([Chord.parse("ctrl+tab")!: .nextTab])
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try tabKeyDown(flags: .control)))
        XCTAssertEqual(fired, [.nextTab])
    }

    func test_ctrlTab_isNotAShippedDefault() throws {
        let keys = KeyInterceptor()
        let event = try tabKeyDown(flags: .control)
        XCTAssertIdentical(keys.route(event), event)
    }

    func test_bareTab_reachesTheProgram() throws {
        let keys = KeyInterceptor()
        let event = try tabKeyDown(flags: [])
        XCTAssertIdentical(keys.route(event), event)
    }

    private func tabKeyDown(flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false,
                keyCode: 48))
    }

    func test_aHeldPageKeyRepeatsAndAHeldHomeKeyDoesNot() throws {
        let keys = KeyInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 121, character: "\u{F72D}", isARepeat: true)))
        XCTAssertNil(keys.route(try functionKeyDown(keyCode: 115, character: "\u{F729}", isARepeat: true)))

        XCTAssertEqual(fired, [.scrollPageDown])
    }

    func test_theShiftedArrowSpellingOfAPromptJumpFires() throws {
        let keys = KeyInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(keys.route(try arrowKeyDown(keyCode: 126, character: "\u{F700}", shift: true)))
        XCTAssertNil(keys.route(try arrowKeyDown(keyCode: 125, character: "\u{F701}", shift: true)))

        XCTAssertEqual(fired, [.jumpToPreviousPrompt, .jumpToNextPrompt])
    }

    func test_theBareArrowSpellingIsNotClaimed() throws {
        let keys = KeyInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        let up = try arrowKeyDown(keyCode: 126, character: "\u{F700}")
        let down = try arrowKeyDown(keyCode: 125, character: "\u{F701}")

        XCTAssertIdentical(keys.route(up), up)
        XCTAssertIdentical(keys.route(down), down)
        XCTAssertEqual(fired, [])
    }

    func test_aHeldPromptJumpRepeats() throws {
        let keys = KeyInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        XCTAssertNil(
            keys.route(
                try arrowKeyDown(
                    keyCode: 126, character: "\u{F700}", shift: true, isARepeat: true)))

        XCTAssertEqual(fired, [.jumpToPreviousPrompt])
    }

    private func functionKeyDown(keyCode: UInt16, character: String, isARepeat: Bool = false) throws
        -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .function], timestamp: 0,
                windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: isARepeat, keyCode: keyCode))
    }

    func test_theShippedCreateWorktreeChord_routesAndDefersByPickerState() throws {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        var pickerIsOpen = true
        keys.passThroughGuard = { _, action in
            PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: pickerIsOpen, sidebarHasFocus: false)
        }
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }
        let event = try optionReturn()

        XCTAssertNil(keys.route(event), "consumed while the picker is up")
        XCTAssertEqual(fired, [.createWorktree])

        pickerIsOpen = false
        XCTAssertNotNil(
            keys.route(event), "handed back to the terminal, where ⌥⏎ is a newline in a TUI")
        XCTAssertEqual(fired, [.createWorktree], "no second dispatch")
    }

    private func optionReturn() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private func arrowKeyDown(
        keyCode: UInt16, character: String, shift: Bool = false, option: Bool = false,
        control: Bool = false, isARepeat: Bool = false
    ) throws -> NSEvent {
        var flags: NSEvent.ModifierFlags = [.command, .function, .numericPad]
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: isARepeat, keyCode: keyCode))
    }

    func test_theNavAndResizeArrowsFireThroughTheRealEventShape() throws {
        let keys = KeyInterceptor()
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }

        for (keyCode, character) in [(123, "\u{F702}"), (124, "\u{F703}"), (126, "\u{F700}"), (125, "\u{F701}")] {
            XCTAssertNil(keys.route(try arrowKeyDown(keyCode: UInt16(keyCode), character: character, option: true)))
            XCTAssertNil(keys.route(try arrowKeyDown(keyCode: UInt16(keyCode), character: character, control: true)))
        }

        XCTAssertEqual(
            fired,
            [
                .navLeft, .resizeLeft, .navRight, .resizeRight, .navUp, .resizeUp, .navDown,
                .resizeDown,
            ])
    }

    func test_anUnboundModifiedKeyFallsToTheMode() throws {
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
        let keys = interceptor()
        keys.passThroughGuard = { _, _ in true }
        var reachedMode = false
        keys.modeHandler = { _ in
            reachedMode = true
            return true
        }

        XCTAssertNil(keys.route(try keyDown("d", flags: .control)))
        XCTAssertTrue(reachedMode)
    }

    func test_captureBeatsTheModeEntirely() throws {
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

    func test_aVetoedChordStillRepeatsIntoTheProgram() throws {
        let keys = KeyInterceptor()
        keys.setKeymap([Chord(control: true, key: "h"): .navLeft])
        keys.passThroughGuard = { _, _ in true }

        let event = try keyDown("h", flags: .control, isARepeat: true)
        XCTAssertIdentical(keys.route(event), event)
    }

    func test_flagsChangedNeverReachesTheMode() throws {
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

    func test_aModifierMoveFansOutAndStillReachesTheResponderChain() throws {
        let keys = interceptor()
        var fanned: [UInt16] = []
        keys.onModifierChange = { fanned.append($0.keyCode) }

        let event = try commandDown()
        XCTAssertIdentical(
            keys.route(event), event,
            "the fan-out observes the event; consuming it would starve the focused pane")
        XCTAssertEqual(
            fanned, [0x37],
            "every pane but one is skipped by the responder chain, so route has to fan the move out")
    }

    func test_aModifierMoveNeverFansOutWhileCapturingAKeybind() throws {
        let keys = interceptor()
        var fanned = 0
        keys.onModifierChange = { _ in fanned += 1 }
        keys.beginCapture { _ in }

        XCTAssertNil(keys.route(try commandDown()))
        XCTAssertEqual(fanned, 0, "a captured chord reaches no pane, so the fan-out must not either")
    }
}
