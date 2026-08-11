import XCTest

@testable import ZenTerm

/// Guards ZenTerm's hardcoded resource-bundle name against drift. If the package or
/// target is renamed, or a toolchain changes the `<Package>_<Target>` scheme,
/// `Bundle.module` (which resolves under `swift test` via its `.build` path) reports
/// a different name and this fails the gate instead of re-shipping the launch
/// crash to downloaders, whose brand marks, themes, and license notices would all
/// silently fail to load.
final class ZenTermResourcesTests: XCTestCase {
    func test_bundleName_matchesEmittedBundle() {
        XCTAssertEqual(
            "\(ZenTermResources.bundleName).bundle",
            Bundle.module.bundleURL.lastPathComponent)
    }
}
