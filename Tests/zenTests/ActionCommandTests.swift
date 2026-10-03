import XCTest

@testable import zen

final class ActionCommandTests: XCTestCase {
    func test_theActionNameIsItsArgument() throws {
        let action = try XCTUnwrap(try Zen.parseAsRoot(["action", "toggle_sidebar"]) as? Zen.Action)
        XCTAssertEqual(action.name, "toggle_sidebar")
    }
}
