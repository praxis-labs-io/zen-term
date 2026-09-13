import XCTest

@testable import ZenTerm

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
