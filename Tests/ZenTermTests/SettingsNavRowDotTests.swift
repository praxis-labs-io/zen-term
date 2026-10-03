import AppKit
import XCTest

@testable import ZenTerm

final class SettingsNavRowDotTests: XCTestCase {
    func test_aThemeChange_repaintsTheDotFromItsInk() {
        var ink = NSColor.systemRed
        let row = SettingsNavRow(title: "devbox") {}
        row.setDot({ ink }, accessibilityValue: "Online")

        ink = NSColor.systemGreen
        row.reapplyTheme()

        XCTAssertEqual(row.dotColorForTesting, NSColor.systemGreen.cgColor)
    }

    func test_noInk_hidesTheDotAndItsValue() {
        let row = SettingsNavRow(title: "devbox") {}
        row.setDot({ .systemRed }, accessibilityValue: "Online")

        row.setDot(nil, accessibilityValue: "Online")

        XCTAssertFalse(row.showsAttentionForTesting)
        XCTAssertNil(row.accessibilityValue())
    }
}
