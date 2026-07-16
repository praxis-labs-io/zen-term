import XCTest

@testable import ZenTerm

/// Guards the asset-catalog wiring: the dock's brand marks must actually resolve from the
/// bundle, else a float button using `icon:github`/`icon:git` renders blank. Exercises ZenTerm's own
/// `Bundle.module` (BrandMark is compiled into ZenTerm, so it reads ZenTerm's resources).
final class BrandMarkTests: XCTestCase {
    func test_bundledMarks_load() {
        XCTAssertNotNil(BrandMark.image("github"), "GitHub mark must be bundled")
        XCTAssertNotNil(BrandMark.image("git"), "git mark must be bundled")
        XCTAssertNotNil(BrandMark.image("origami"), "origami mark must be bundled for the Settings footer")
    }

    func test_unknownMark_isNil() {
        XCTAssertNil(BrandMark.image("not-a-real-mark"))
    }
}
