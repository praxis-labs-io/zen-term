import XCTest

@testable import ZenTerm

final class NavGuardTests: XCTestCase {
    func test_ctrlNavOverVimPane_passesThrough() {
        for action in [KeyInterceptor.ReservedChord.navLeft, .navRight, .navUp, .navDown] {
            XCTAssertTrue(
                NavGuard.shouldPassThrough(
                    chord: Chord(control: true, key: "h"), action: action, focusedPaneIsVim: true),
                "Ctrl-nav over an nvim pane should pass through for \(action)")
        }
    }

    func test_ctrlNavOverNonVimPane_consumed() {
        XCTAssertFalse(
            NavGuard.shouldPassThrough(
                chord: Chord(control: true, key: "h"), action: .navLeft, focusedPaneIsVim: false))
    }

    func test_cmdNavOverVimPane_consumed() {
        // The default ⌘-nav is never diverted, even over an nvim pane.
        XCTAssertFalse(
            NavGuard.shouldPassThrough(
                chord: Chord(command: true, key: "h"), action: .navLeft, focusedPaneIsVim: true))
    }

    func test_ctrlCmdNav_consumed() {
        // A chord carrying ⌘ alongside Ctrl is not the seamless-nav opt-in chord.
        XCTAssertFalse(
            NavGuard.shouldPassThrough(
                chord: Chord(command: true, control: true, key: "h"), action: .navLeft,
                focusedPaneIsVim: true))
    }

    func test_ctrlNonNavOverVimPane_consumed() {
        // Only nav is diverted — a Ctrl-bound non-nav chord still fires normally.
        XCTAssertFalse(
            NavGuard.shouldPassThrough(
                chord: Chord(control: true, key: "w"), action: .closePane, focusedPaneIsVim: true))
    }
}

final class KeyInterceptorResolveTests: XCTestCase {
    private func interceptor(guard g: ((Chord, KeyInterceptor.ReservedChord) -> Bool)? = nil)
        -> KeyInterceptor
    {
        let interceptor = KeyInterceptor()
        interceptor.setKeymap([
            Chord(control: true, key: "h"): .navLeft,
            Chord(command: true, key: "h"): .navLeft,
        ])
        interceptor.passThroughGuard = g
        return interceptor
    }

    func test_unboundChord_passesThrough() {
        XCTAssertEqual(interceptor().resolve(Chord(control: true, key: "x")), .passThrough)
    }

    func test_nilChord_passesThrough() {
        XCTAssertEqual(interceptor().resolve(nil), .passThrough)
    }

    func test_boundChord_noGuard_consumes() {
        XCTAssertEqual(interceptor().resolve(Chord(control: true, key: "h")), .consume(.navLeft))
    }

    func test_guardVeto_passesThrough() {
        let interceptor = interceptor { chord, action in
            NavGuard.shouldPassThrough(chord: chord, action: action, focusedPaneIsVim: true)
        }
        // Ctrl-nav vetoed → passes through; ⌘-nav still consumed.
        XCTAssertEqual(interceptor.resolve(Chord(control: true, key: "h")), .passThrough)
        XCTAssertEqual(interceptor.resolve(Chord(command: true, key: "h")), .consume(.navLeft))
    }
}
