import AppKit
import XCTest

@testable import ZenTerm

final class NavRowDotTests: XCTestCase {
    func test_aThemeChange_repaintsTheDotFromItsInk() {
        var ink = NSColor.systemRed
        let row = NavRow(title: "devbox") {}
        row.setDot({ ink }, accessibilityValue: "Online")

        ink = NSColor.systemGreen
        row.reapplyThemeTree()

        XCTAssertEqual(row.dotColorForTesting, NSColor.systemGreen.cgColor)
    }

    func test_noInk_hidesTheDotAndItsValue() {
        let row = NavRow(title: "devbox") {}
        row.setDot({ .systemRed }, accessibilityValue: "Online")

        row.setDot(nil, accessibilityValue: "Online")

        XCTAssertFalse(row.showsAttentionForTesting)
        XCTAssertNil(row.accessibilityValue())
    }
}
