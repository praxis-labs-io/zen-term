import XCTest

@testable import ZenTerm

final class ZenTermResourcesTests: XCTestCase {
    func test_bundleName_matchesEmittedBundle() {
        XCTAssertEqual(
            "\(ZenTermResources.bundleName).bundle",
            Bundle.module.bundleURL.lastPathComponent)
    }
}
