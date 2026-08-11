import AppKit
import XCTest

@testable import ZenTerm

/// The Settings nav footer's version line. It used to read "ZenTerm v<version>", which
/// fit a release build and overflowed every dev one — `bin/package-app` stamps `<tag>-dev`, so
/// "ZenTerm v0.0.0-dev" ran under the divider, clipped, because a plain label doesn't truncate.
///
/// Asserting the string would have caught none of that, so these measure it against the real
/// column, in the real font.
///
/// The versions are named explicitly rather than read from `AppVersion.current`: under xctest the
/// bundle reports the *test runner's* version ("16.0"), so measuring the live string here would
/// prove nothing about what ZenTerm actually renders.
final class SettingsNavFooterTests: WindowTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: SettingsOverlay.versionFont]).width
    }

    func test_versionLine_fitsTheNavColumn_forEveryVersionShapeWeShip() {
        // The versions `bin/package-app` can actually produce: a release tag, a daily driver N
        // commits past one, the untagged and `swift run` fallbacks, and a two-digit build with a
        // three-digit commit count (the widest shape the "+N" scheme can reach).
        for version in ["0.1.0", "0.1.0+7", "0.0.0+121", "0.0.0+src", "0.10.12+123", "1.0.0-beta.1"] {
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

    /// The label must be BOUND to the column, so a version string nobody predicted degrades to an
    /// ellipsis instead of running under the divider like the old one did. Asserting
    /// `lineBreakMode` here would only read back the property the code just set — it would pass with
    /// the width constraint deleted, which is the half that actually does the work.
    func test_versionLabel_laysOutWithinTheColumn_evenForAnAbsurdVersion() throws {
        let overlay = mountedOverlay()
        let versionLabel = try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == SettingsOverlay.versionText }, "no version label mounted")

        versionLabel.stringValue = "v99.99.99-rc.1+build.20260716.deadbeef"
        overlay.layoutSubtreeIfNeeded()

        // What must hold is that the footer stays inside the nav column — the label's own cap is
        // just the mechanism. Measure the requirement, not the implementation detail.
        let footer = try XCTUnwrap(versionLabel.superview)
        let column = try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? NSScrollView }
                .first { $0.contentView is FlippedClipView }, "no nav column")
        let footerFrame = footer.convert(footer.bounds, to: overlay)
        let columnFrame = column.convert(column.bounds, to: overlay)
        XCTAssertLessThanOrEqual(
            footerFrame.maxX, columnFrame.maxX,
            "the footer must not run past the nav column into the divider")
        XCTAssertGreaterThanOrEqual(footerFrame.minX, columnFrame.minX, "nor off the card's leading edge")
    }

    /// The mark and version read as one unit centered in the nav column, not hung off its edge.
    func test_navFooter_isCenteredInTheNavColumn() throws {
        let overlay = mountedOverlay()
        let mark = try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? NSImageView }.first, "no brand mark mounted")
        let footer = try XCTUnwrap(mark.superview, "the mark should sit in the footer stack")
        overlay.layoutSubtreeIfNeeded()

        let column = try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? NSScrollView }
                .first { $0.contentView is FlippedClipView }, "no nav column")
        let footerCenter = footer.convert(footer.bounds, to: overlay).midX
        let columnCenter = column.convert(column.bounds, to: overlay).midX

        XCTAssertEqual(footerCenter, columnCenter, accuracy: 0.5, "the footer must centre on the nav column")
    }

    private func mountedOverlay() -> SettingsOverlay {
        let overlay = SettingsOverlay(
            sections: [], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        self.window = window
        overlay.layoutSubtreeIfNeeded()
        return overlay
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
