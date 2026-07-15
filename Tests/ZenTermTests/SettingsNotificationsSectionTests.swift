import AppKit
import XCTest

@testable import ZenTerm

/// Interaction test for the Notifications settings section (ZEN-139): mount the real section in a
/// window, drive its On/Off segmented control the way a click would, and assert the value that
/// actually lands in the config file. A state-only assertion would pass while the control is dead —
/// exactly how a broken dropdown once shipped past two reviews — so this drives the control itself.
///
/// The write→reload pipeline is rooted at `ConfigLoader.defaultRoot`; the test points that at a temp
/// dir via `defaultRootOverrideForTesting` so it never touches the real config.
final class SettingsNotificationsSectionTests: XCTestCase {
    private var tempRoot: URL!
    /// Retained for the test's lifetime: the row's `onChange` captures the section `[weak self]`, so
    /// a deallocated section would silently no-op the write.
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-notifications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // GeneralConfig.current now reflects the empty temp root (= builtIn: on)
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Mount the section (section + window retained) and return its segmented control.
    private func mountSegment(_ section: SettingsNotificationsSection) -> SegmentedControl {
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        hostWindow = window
        return descendants(of: detail).compactMap { $0 as? SegmentedControl }.first!
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    func test_selectingOff_writesFalse() {
        let segment = mountSegment(SettingsNotificationsSection())
        XCTAssertEqual(segment.selectedIndex, 0, "default is On")

        segment.select(1)  // drive the Off segment as a click would

        XCTAssertTrue(
            configText().contains("agent-notifications = false"), "got: \(configText())")
    }

    func test_selectingOnAfterOff_writesTrue() {
        let segment = mountSegment(SettingsNotificationsSection())
        segment.select(1)  // Off
        XCTAssertTrue(configText().contains("agent-notifications = false"))

        segment.select(0)  // back to On

        XCTAssertTrue(
            configText().contains("agent-notifications = true"), "got: \(configText())")
    }
}
