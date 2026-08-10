import AppKit
import XCTest

@testable import ZenTerm

/// A settings row's description has to fit the width the row gives it. The description was a
/// single-line label facing a spacer, so it kept its full width, lost the compression fight with the
/// control beside it, and truncated mid-sentence: the Accent color row read "The color for focus,
/// active state, and".
///
/// Measured rather than eyeballed, because this is the one thing the eye can't check reliably — the
/// wrap column depends on the control's width, so a row can read fine next to a 64pt field and clip
/// next to a 220pt dropdown.
final class SettingsRowDescriptionTests: WindowTestCase {
    private var tempRoot: URL!
    private var window: NSWindow?
    private var overlay: SettingsOverlay?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-row-desc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        try "".write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        window = nil
        overlay = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The whole Settings card, so every width is the one production computes: the 620pt card, its
    /// 168pt nav, the divider, and the detail scroll's insets. Hardcoding a detail width in the test
    /// is how a first attempt at this passed while the app clipped — it measured a pane 54pt wider
    /// than the card ever gives a row.
    private func mount(_ section: any SettingsSection) -> NSView {
        let card = SettingsOverlay(
            sections: [section], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        card.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        card.layoutSubtreeIfNeeded()
        self.window = window
        self.overlay = card
        return card
    }

    /// Every 10pt note label in the section: the description under a caption and the range under a
    /// field both use it.
    private func notes(in detail: NSView) -> [NSTextField] {
        descendants(of: detail)
            .compactMap { $0 as? NSTextField }
            .filter { $0.font == .systemFont(ofSize: 10) }
    }

    /// The height the label's text needs at the width it was laid out to. Bigger than the frame means
    /// what's on screen is a clipped copy of the string.
    ///
    /// Measured from the plain string and its font, NOT `attributedStringValue`: a label's attributed
    /// string carries its own paragraph style, and a truncating one reports every string as one line
    /// no matter how narrow the box. A first version of this test measured that and passed against the
    /// clipped build.
    private func neededHeight(of label: NSTextField) -> CGFloat {
        guard let font = label.font else { return 0 }
        return (label.stringValue as NSString).boundingRect(
            with: NSSize(width: label.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
    }

    func test_appearanceSection_everyDescriptionFitsItsRow() {
        let detail = mount(SettingsAppearanceSection())
        let labels = notes(in: detail)
        XCTAssertFalse(labels.isEmpty, "expected the section to render descriptions")

        for label in labels {
            XCTAssertGreaterThan(label.frame.width, 0, "\(label.stringValue) was never laid out")
            XCTAssertGreaterThanOrEqual(
                label.frame.height + 0.5, neededHeight(of: label),
                "clipped: \"\(label.stringValue)\" needs more room than the \(Int(label.frame.width))pt it got")
        }
    }

    /// The Terminal section pairs long descriptions with narrow numeric fields, the other side of the
    /// same layout.
    func test_terminalSection_everyDescriptionFitsItsRow() {
        let detail = mount(SettingsTerminalSection())
        let labels = notes(in: detail)
        XCTAssertFalse(labels.isEmpty, "expected the section to render descriptions")

        for label in labels {
            XCTAssertGreaterThanOrEqual(
                label.frame.height + 0.5, neededHeight(of: label),
                "clipped: \"\(label.stringValue)\" needs more room than the \(Int(label.frame.width))pt it got")
        }
    }
}
