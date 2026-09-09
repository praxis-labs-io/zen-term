import XCTest

@testable import ZenTerm

/// The truth table for the chords that only mean something over the workspace picker.
final class PickerChordGuardTests: XCTestCase {
    private static let pickerOnly: [KeyInterceptor.ReservedChord] = [.createWorktree, .removeWorktree]

    func test_pickerChords_reachTheTerminalWhenThePickerIsClosed() {
        for action in Self.pickerOnly {
            XCTAssertTrue(
                PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: false),
                action.actionToken)
        }
    }

    func test_pickerChords_areOursWhileThePickerIsOpen() {
        for action in Self.pickerOnly {
            XCTAssertFalse(
                PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: true),
                action.actionToken)
        }
    }

    /// A new case joining the pass-through arm would hand a working chord to the terminal.
    func test_everyOtherAction_isNeverPassedThrough() {
        for action in SettingsKeybindGroupsTests.everyAction where !Self.pickerOnly.contains(action) {
            for pickerIsOpen in [true, false] {
                XCTAssertFalse(
                    PickerChordGuard.shouldPassThrough(
                        action: action, repoPickerIsOpen: pickerIsOpen),
                    "\(action.actionToken) with the picker \(pickerIsOpen ? "open" : "closed")")
            }
        }
    }
}
