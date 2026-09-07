import XCTest

@testable import ZenTerm

/// The truth table for the one chord that only means something over the workspace picker. Pure, so
/// it is testable without an event loop, mirroring `NavGuardTests`.
final class PickerChordGuardTests: XCTestCase {
    func test_createWorktree_reachesTheTerminalWhenThePickerIsClosed() {
        XCTAssertTrue(
            PickerChordGuard.shouldPassThrough(action: .createWorktree, repoPickerIsOpen: false))
    }

    func test_createWorktree_isOursWhileThePickerIsOpen() {
        XCTAssertFalse(
            PickerChordGuard.shouldPassThrough(action: .createWorktree, repoPickerIsOpen: true))
    }

    /// Every other action is the app's in both states. A new case that silently joined the
    /// pass-through arm would hand a working chord to the terminal.
    func test_everyOtherAction_isNeverPassedThrough() {
        for action in SettingsKeybindGroupsTests.everyAction where action != .createWorktree {
            for pickerIsOpen in [true, false] {
                XCTAssertFalse(
                    PickerChordGuard.shouldPassThrough(
                        action: action, repoPickerIsOpen: pickerIsOpen),
                    "\(action.actionToken) with the picker \(pickerIsOpen ? "open" : "closed")")
            }
        }
    }
}
