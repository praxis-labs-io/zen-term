import XCTest

@testable import ZenTerm

final class ToolFloatCatalogTests: XCTestCase {
    func test_ids_areUnique() {
        let ids = ToolFloatCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ToolFloat ids must be unique")
    }

    func test_diffnav_isPresentWithExpectedSpec() {
        let f = ToolFloatCatalog.byID("diffnav")
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.command, "git diff main")
        XCTAssertEqual(f?.shortcut, "⌘⇧G")
        XCTAssertEqual(f?.widthFraction, 0.85)
        XCTAssertEqual(f?.heightFraction, 0.85)
        XCTAssertTrue(f?.requiresGitRepo == true)
        XCTAssertEqual(f?.emptyGuard?.probe, "git diff main --quiet")
    }

    func test_byID_unknown_isNil() {
        XCTAssertNil(ToolFloatCatalog.byID("nope"))
    }
}
