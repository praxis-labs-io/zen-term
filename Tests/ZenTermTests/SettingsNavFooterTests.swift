import AppKit
import XCTest

@testable import ZenTerm

/// The Settings nav footer's version line (ZEN-151). It used to read "ZenTerm v<version>", which
/// fit a release build and overflowed every dev one — `bin/package-app` stamps `<tag>-dev`, so
/// "ZenTerm v0.0.0-dev" ran under the divider, clipped, because a plain label doesn't truncate.
///
/// Asserting the string would have caught none of that, so these measure it against the real
/// column, in the real font.
///
/// The versions are named explicitly rather than read from `AppVersion.current`: under xctest the
/// bundle reports the *test runner's* version ("16.0"), so measuring the live string here would
/// prove nothing about what ZenTerm actually renders.
final class SettingsNavFooterTests: XCTestCase {
    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: SettingsOverlay.versionFont]).width
    }

    func test_versionLine_fitsTheNavColumn_forEveryVersionShapeWeShip() {
        // A release tag, a dev build (the shape that overflowed), and a two-digit dev build — the
        // versions `bin/package-app` can actually produce.
        for version in ["0.1.0", "0.0.0-dev", "0.10.12-dev", "1.0.0-beta.1"] {
            let text = "v\(version)"
            XCTAssertLessThanOrEqual(
                width(text), SettingsOverlay.versionMaxWidth,
                "\"\(text)\" renders \(width(text))pt into a \(SettingsOverlay.versionMaxWidth)pt column")
        }
    }

    /// The wordmark is what blew the budget: the crane mark carries the brand instead.
    func test_versionLine_isBareVersion_notTheWordmark() {
        XCTAssertTrue(
            SettingsOverlay.versionText.hasPrefix("v"),
            "the footer shows the bare version — \(SettingsOverlay.versionText)")
        XCTAssertFalse(
            SettingsOverlay.versionText.contains("ZenTerm"),
            "'ZenTerm v<version>' overflows the nav on every dev build")
    }

    /// The label must also truncate, so a version string nobody predicted degrades to an ellipsis
    /// instead of running under the divider like the old one did.
    func test_versionLabel_truncatesRatherThanSpilling() throws {
        let overlay = SettingsOverlay(
            sections: [], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        let labels = descendants(of: overlay).compactMap { $0 as? NSTextField }
        let versionLabel = try XCTUnwrap(
            labels.first { $0.stringValue == SettingsOverlay.versionText }, "no version label mounted")
        XCTAssertEqual(versionLabel.lineBreakMode, .byTruncatingTail)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
