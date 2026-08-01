import GhosttyKit
import XCTest

@testable import TerminalKit

/// `GHOSTTY_ACTION_COMMAND_FINISHED` carries a signed sentinel exit code and a nanosecond duration.
/// Pin both conversions at the backend boundary so the chrome never learns those wire details.
final class GhosttyCommandFinishedTests: XCTestCase {
    func test_reportedExitCodeAndDurationCrossTheSeam() {
        let result = GhosttySurface.commandResult(
            ghostty_action_command_finished_s(exit_code: 17, duration: 126_000_000_000))

        XCTAssertEqual(result, TerminalCommandResult(exitCode: 17, duration: 126))
    }

    func test_unreportedExitCodeBecomesNil() {
        let result = GhosttySurface.commandResult(
            ghostty_action_command_finished_s(exit_code: -1, duration: 500_000_000))

        XCTAssertNil(result.exitCode)
        XCTAssertEqual(result.duration, 0.5)
    }
}
