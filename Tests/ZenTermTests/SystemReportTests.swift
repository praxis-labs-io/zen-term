import XCTest

@testable import ZenTerm

final class SystemReportTests: XCTestCase {
    func test_plainText_rendersEveryField() {
        let report = SystemReport(
            appVersion: "0.3.0", build: "1234", osVersion: "15.5 (24F74)", architecture: "arm64")
        XCTAssertEqual(
            report.plainText,
            """
            - ZenTerm: v0.3.0 (build 1234)
            - macOS: 15.5 (24F74)
            - Architecture: arm64
            """)
    }

    func test_plainText_dropsBuildFragmentWhenNil() {
        // A `swift run` build has no CFBundleVersion; the block must not render a bare "(build )".
        let report = SystemReport(
            appVersion: "0.0.0+src", build: nil, osVersion: "15.5 (24F74)", architecture: "arm64")
        XCTAssertEqual(
            report.plainText,
            """
            - ZenTerm: v0.0.0+src
            - macOS: 15.5 (24F74)
            - Architecture: arm64
            """)
        XCTAssertFalse(report.plainText.contains("build"), "no build fragment when the build is unknown")
    }
}
