import XCTest

@testable import ZenTerm

/// ⌥⏎ and ⌥⌫ mean something only over the workspace picker, and `KeyInterceptor.resolve` consumes
/// every chord in the keymap regardless of what is on screen. Without this guard both are dead keys
/// in every pane: ⌥⌫ is delete-previous-word in readline, ⌥⏎ is newline-without-submit in Claude
/// Code, and `WindowController.handle` drops them in silence when no picker is up.
final class PickerChordGuardTests: XCTestCase {
    private func passesThrough(_ action: KeyInterceptor.ReservedChord, pickerOpen: Bool) -> Bool {
        PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: pickerOpen)
    }

    func test_theClonesChords_reachTheTerminalWhenNoPickerIsOpen() {
        XCTAssertTrue(passesThrough(.cloneWorkspace, pickerOpen: false))
        XCTAssertTrue(passesThrough(.removeClone, pickerOpen: false))
    }

    func test_theClonesChords_areClaimedWhileThePickerIsOpen() {
        XCTAssertFalse(passesThrough(.cloneWorkspace, pickerOpen: true))
        XCTAssertFalse(passesThrough(.removeClone, pickerOpen: true))
    }

    /// The guard is scoped to these two. Diverting anything else would hand a working chord to the
    /// terminal, which is the mirror of the bug it exists to fix.
    func test_everyOtherActionIsUntouched_inBothStates() {
        let others: [KeyInterceptor.ReservedChord] = [
            .newTab, .closePane, .toggleRepoPicker, .toggleCommandPalette, .navLeft, .navRight,
            .fillScreen, .toggleZoom, .openSettings, .dismissToast, .splitVertical,
        ]
        for action in others {
            XCTAssertFalse(passesThrough(action, pickerOpen: true), "\(action)")
            XCTAssertFalse(passesThrough(action, pickerOpen: false), "\(action)")
        }
    }

    /// The whole point is what `KeyInterceptor` does with the answer: a vetoed chord defers to the
    /// program in the pane rather than being consumed and dropped.
    func test_interceptor_defersTheChordToTheTerminalWhenTheGuardVetoes() {
        let interceptor = KeyInterceptor()
        interceptor.setKeymap(KeymapDefaults.map)
        interceptor.passThroughGuard = { _, action in
            PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: false)
        }

        XCTAssertEqual(interceptor.resolve(Chord(option: true, key: "⌫")), .deferToTerminal)
        XCTAssertEqual(interceptor.resolve(Chord(option: true, key: "⏎")), .deferToTerminal)
    }

    func test_interceptor_consumesTheChordWhileThePickerIsOpen() {
        let interceptor = KeyInterceptor()
        interceptor.setKeymap(KeymapDefaults.map)
        interceptor.passThroughGuard = { _, action in
            PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: true)
        }

        XCTAssertEqual(interceptor.resolve(Chord(option: true, key: "⌫")), .consume(.removeClone))
        XCTAssertEqual(interceptor.resolve(Chord(option: true, key: "⏎")), .consume(.cloneWorkspace))
    }
}
