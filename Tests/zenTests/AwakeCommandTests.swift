import XCTest

@testable import zen

final class AwakeCommandTests: XCTestCase {
    func test_forTakesHoursMinutesAndSeconds_inThatOrder() throws {
        let on = try XCTUnwrap(try Zen.parseAsRoot(["awake", "on", "--for", "1h30m"]) as? AwakeCommands.Hold)
        XCTAssertEqual(on.duration?.seconds, 90 * 60)
        XCTAssertEqual(AwakeDuration(argument: "2h")?.seconds, 2 * 60 * 60)
        XCTAssertEqual(AwakeDuration(argument: "45m")?.seconds, 45 * 60)
        XCTAssertEqual(AwakeDuration(argument: "90s")?.seconds, 90)
        XCTAssertEqual(AwakeDuration(argument: "1h0m5s")?.seconds, 60 * 60 + 5)
    }

    func test_aPlainOnHoldsUntilOff() throws {
        let on = try XCTUnwrap(try Zen.parseAsRoot(["awake", "on"]) as? AwakeCommands.Hold)
        XCTAssertNil(on.duration)
        XCTAssertNoThrow(try Zen.parseAsRoot(["awake", "off"]) as? AwakeCommands.Release)
        XCTAssertNoThrow(try Zen.parseAsRoot(["awake", "status"]) as? AwakeCommands.Status)
    }

    func test_aDurationWithoutAUnitOrOutOfOrderIsAUsageError() {
        for bad in ["90", "m", "0m", "30m1h", "1h1h", "1.5h", "-5m", "1d", "", "9999999h"] {
            XCTAssertNil(AwakeDuration(argument: bad), bad)
        }
        XCTAssertEqual(Zen.exitCode(parsing: ["awake", "on", "--for", "90"]), 2)
        XCTAssertEqual(Zen.exitCode(parsing: ["awake", "on", "--for", "168h"]), 0)
        XCTAssertEqual(Zen.exitCode(parsing: ["awake", "on", "--for", "168h1s"]), 2, "past a week")
    }
}
