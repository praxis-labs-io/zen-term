import XCTest

@testable import ZenTerm

final class ToolFloatCatalogTests: XCTestCase {
    func test_ids_areUnique() {
        let ids = ToolFloatCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ToolFloat ids must be unique")
    }

    func test_gitdash_isPresentWithExpectedSpec() {
        let f = ToolFloatCatalog.byID("gitdash")
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.command, "gd")
        XCTAssertEqual(f?.shortcut, "⌘⇧G")
        XCTAssertEqual(f?.widthFraction, 0.85)
        XCTAssertEqual(f?.heightFraction, 0.85)
        XCTAssertTrue(f?.requiresGitRepo == true)
        XCTAssertNil(f?.emptyGuard)  // a GitHub dashboard isn't diff-state-gated
    }

    func test_byID_unknown_isNil() {
        XCTAssertNil(ToolFloatCatalog.byID("nope"))
    }
}
