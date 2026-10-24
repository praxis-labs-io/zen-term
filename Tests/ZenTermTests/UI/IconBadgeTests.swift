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
        XCTAssertEqual(badge.layer?.cornerRadius, ChromeMetrics.Radius.control)
        XCTAssertEqual(toast.badgeFillForTesting, chrome.tint(role, alpha: ChromeTheme.badgeTint).cgColor)
        XCTAssertEqual(toast.badgeIconTintForTesting, role.nsColor)
    }

    func test_anUpdateCardsBadge_isTheBrandMarkOnAnAccentChip() throws {
        let card = UpdateCardView(
            state: .available(version: "9.9.9", current: "You're on 1.0", notes: [], notesURL: nil),
            actions: .init())
        let chrome = Theme.current.chrome
        let badge = card.badgeForTesting
        badge.layoutSubtreeIfNeeded()

        XCTAssertEqual(badge.fittingSize, NSSize(width: 28, height: 28))
        XCTAssertEqual(badge.layer?.cornerRadius, ChromeMetrics.Radius.control)
        XCTAssertEqual(card.badgeFillForTesting, chrome.tint(chrome.accent, alpha: ChromeTheme.badgeTint).cgColor)
        XCTAssertEqual(card.badgeIconTintForTesting, chrome.accent.nsColor)
        XCTAssertNotNil(badge.iconImageForTesting)
        XCTAssertEqual(badge.iconFrameForTesting.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(badge.iconFrameForTesting.midX, 14, accuracy: 0.5)
        XCTAssertEqual(badge.iconFrameForTesting.midY, 14, accuracy: 0.5)
    }
}
