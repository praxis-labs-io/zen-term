import AppKit
import XCTest

@testable import ZenTerm

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

    private func notes(in detail: NSView) -> [NSTextField] {
        descendants(of: detail)
            .compactMap { $0 as? NSTextField }
            .filter { $0.font == .systemFont(ofSize: 10) }
    }

    /// Measures the plain string: a truncating paragraph style reports one line at any width.
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
