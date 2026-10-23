import XCTest

@testable import ZenTerm

final class PickerChordGuardTests: XCTestCase {
    private static let pickerOnly: [KeyInterceptor.ReservedChord] = [.createWorktree, .removeWorktree]

    func test_pickerChords_reachTheTerminalWhenThePickerIsClosed() {
        for action in Self.pickerOnly {
            XCTAssertTrue(
                PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: false, sidebarHasFocus: false),
                action.actionToken)
        }
    }

    func test_pickerChords_areOursWhileThePickerIsOpen() {
        for action in Self.pickerOnly {
            XCTAssertFalse(
                PickerChordGuard.shouldPassThrough(action: action, repoPickerIsOpen: true, sidebarHasFocus: false),
                action.actionToken)
        }
    }

    func test_createWorktree_isOursWhileTheSidebarHasFocus_butRemoveWorktreeIsNot() {
        XCTAssertFalse(
            PickerChordGuard.shouldPassThrough(action: .createWorktree, repoPickerIsOpen: false, sidebarHasFocus: true))
        XCTAssertTrue(
            PickerChordGuard.shouldPassThrough(action: .removeWorktree, repoPickerIsOpen: false, sidebarHasFocus: true))
    }

    func test_everyOtherAction_isNeverPassedThrough() {
        for action in SettingsKeybindGroupsTests.everyAction where !Self.pickerOnly.contains(action) {
            for pickerIsOpen in [true, false] {
                XCTAssertFalse(
                    PickerChordGuard.shouldPassThrough(
                        action: action, repoPickerIsOpen: pickerIsOpen, sidebarHasFocus: pickerIsOpen),
                    "\(action.actionToken) with the picker \(pickerIsOpen ? "open" : "closed")")
            }
        }
    }
}
