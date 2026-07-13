import XCTest

@testable import ZenTerm

final class PathDisplayTests: XCTestCase {
    private var home: String { PathDisplay.homePath }

    func test_abbreviatingHome_exactHomeBecomesTilde() {
        XCTAssertEqual(PathDisplay.abbreviatingHome(home), "~")
    }

    func test_abbreviatingHome_childCollapses() {
        XCTAssertEqual(PathDisplay.abbreviatingHome(home + "/Dev/zen-term"), "~/Dev/zen-term")
    }

    /// Regression for the AddWorkspace drift bug: a sibling directory that merely shares the home
    /// prefix (no `/` boundary) must NOT be mangled to `~2/proj`.
    func test_abbreviatingHome_siblingPrefixIsLeftUntouched() {
        let sibling = home + "2/proj"
        XCTAssertEqual(PathDisplay.abbreviatingHome(sibling), sibling)
    }

    func test_abbreviatingHome_unrelatedPathUnchanged() {
        XCTAssertEqual(PathDisplay.abbreviatingHome("/tmp/scratch"), "/tmp/scratch")
    }

    func test_isDirectory_trueForExistingDir() {
        XCTAssertTrue(PathDisplay.isDirectory(URL(fileURLWithPath: NSTemporaryDirectory())))
    }

    func test_isDirectory_falseForRegularFile() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("path-display-\(UUID().uuidString).tmp")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(PathDisplay.isDirectory(file))
    }

    func test_isDirectory_falseForMissingPath() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertFalse(PathDisplay.isDirectory(missing))
    }
}
