import XCTest

@testable import ZenTerm

final class BrandMarkTests: XCTestCase {
    func test_bundledMarks_load() {
        XCTAssertNotNil(BrandMark.image("github"), "GitHub mark must be bundled")
        XCTAssertNotNil(BrandMark.image("git"), "git mark must be bundled")
        XCTAssertNotNil(BrandMark.image("linear"), "Linear mark must be bundled")
        XCTAssertNotNil(BrandMark.image("neovim"), "Neovim mark must be bundled")
        XCTAssertNotNil(BrandMark.image("spotify"), "Spotify mark must remain bundled for existing floats")
        XCTAssertNotNil(BrandMark.image("origami"), "origami mark must be bundled for the Settings footer")
    }

    func test_unknownMark_isNil() {
        XCTAssertNil(BrandMark.image("not-a-real-mark"))
        XCTAssertNil(BrandMark.image("not-a-real-mark"), "a miss stays a miss when it's asked twice")
    }

    func test_marksAreIndependentCopies_soResizingOneLeavesTheRestAlone() throws {
        _ = BrandMark.image("git")
        let resized = try XCTUnwrap(BrandMark.image("git"))
        let original = resized.size
        resized.size = NSSize(width: 99, height: 99)

        let fresh = try XCTUnwrap(BrandMark.image("git"))

        XCTAssertEqual(fresh.size, original, "one caller's resize must not reach another's mark")
        XCTAssertTrue(fresh.isTemplate, "the mark stays a template image, so it tints like a symbol")
    }
}
