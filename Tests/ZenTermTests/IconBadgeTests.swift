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

    func test_aLargeBadge_isABitBiggerThanAToasts() {
        let regular = IconBadge(symbol: "server.rack", accessibilityDescription: nil, size: .regular) { $0.accent }
        let large = IconBadge(symbol: "server.rack", accessibilityDescription: nil, size: .large) { $0.accent }

        XCTAssertGreaterThan(large.fittingSize.width, regular.fittingSize.width)
        XCTAssertEqual(large.iconTintForTesting, Theme.current.chrome.accent.nsColor)
    }
}
