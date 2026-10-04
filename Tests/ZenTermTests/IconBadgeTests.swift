import AppKit
import XCTest

@testable import ZenTerm

final class IconBadgeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    func test_aToastsBadge_keepsItsChip_aTintedRoleFillBehindRoleInk() throws {
        let toast = ToastView(content: ToastContent(variant: .warning, title: "Title", message: "Message"))
        let chrome = Theme.current.chrome
        let role = ToastVariant.warning.role(in: chrome)
        let badge = try XCTUnwrap(toast.subviews.lazy.compactMap { $0.subviews.first as? IconBadge }.first)
        badge.layoutSubtreeIfNeeded()

        XCTAssertEqual(badge.fittingSize, NSSize(width: 28, height: 28))
        XCTAssertEqual(badge.layer?.cornerRadius, 7)
        XCTAssertEqual(toast.badgeFillForTesting, chrome.tint(role, alpha: ChromeTheme.badgeTint).cgColor)
        XCTAssertEqual(toast.badgeIconTintForTesting, role.nsColor)
    }
}
