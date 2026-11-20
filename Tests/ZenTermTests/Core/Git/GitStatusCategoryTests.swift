import XCTest

@testable import ZenTerm

final class GitStatusCategoryTests: XCTestCase {
    func test_conflicted_readsDestructive() {
        XCTAssertEqual(GitStatusCategory.conflicted.tone, .role(\.destructive))
    }
}
