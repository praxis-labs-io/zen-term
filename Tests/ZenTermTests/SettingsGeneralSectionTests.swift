import AppKit
import XCTest

@testable import ZenTerm

/// Interaction test for the General settings section: mount the real section in a window, drive its
/// On/Off segmented controls the way a click would, and assert the value that actually lands in the
/// config file. A state-only assertion would pass while the control is dead — exactly how a broken
/// dropdown once shipped past two reviews — so this drives the controls themselves. Notifications
/// (ZEN-139) and Updates (ZEN-19) share this section, so both toggles are exercised here.
///
/// The write→reload pipeline is rooted at `ConfigLoader.defaultRoot`; the test points that at a temp
/// dir via `defaultRootOverrideForTesting` so it never touches the real config.
final class SettingsGeneralSectionTests: XCTestCase {
    private var tempRoot: URL!
    /// Retained for the test's lifetime: the row's `onChange` captures the section `[weak self]`, so
    /// a deallocated section would silently no-op the write.
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-general-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reloadBlocking()  // GeneralConfig.current now reflects the empty temp root (= builtIn: on)
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        drainConfigWrites()  // a write still in flight would land in the real config root
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reloadBlocking()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Mount the section (section + window retained) and return its segmented controls in order —
    /// [0] Notifications, [1] Updates, matching `populate()`.
    private func mountSegments() -> [SegmentedControl] {
        let section = SettingsGeneralSection()
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        hostWindow = window
        return descendants(of: detail).compactMap { $0 as? SegmentedControl }
    }

    /// Wait for the pending write, then read the sandboxed config file. Picking a segment writes off
    /// the main thread (ZEN-17), so reading without waiting reports the file from before the click.
    private func configText() -> String {
        drainConfigWrites()
        let url = ConfigLoader.defaultRoot.appendingPathComponent("config")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func test_bothToggles_arePresent_andDefaultOn() {
        let segments = mountSegments()
        XCTAssertEqual(segments.count, 2, "General holds the Notifications and Updates toggles")
        XCTAssertEqual(segments[0].selectedIndex, 0, "notifications default is On")
        XCTAssertEqual(segments[1].selectedIndex, 0, "automatic updates default is On")
    }

    func test_notifications_selectingOff_writesFalse() {
        let notifications = mountSegments()[0]

        notifications.select(1)  // drive the Off segment as a click would

        XCTAssertTrue(
            configText().contains("agent-notifications = false"), "got: \(configText())")
    }

    func test_updates_selectingOff_thenOn_writesFalseThenTrue() {
        let updates = mountSegments()[1]

        updates.select(1)  // Off
        XCTAssertTrue(
            configText().contains("automatic-update-checks = false"), "got: \(configText())")

        updates.select(0)  // back to On
        XCTAssertTrue(
            configText().contains("automatic-update-checks = true"), "got: \(configText())")
    }

    // MARK: back to the nav (ZEN-217) — a section of stacked segmented rows had no arrow path out

    /// An arrow key as AppKit delivers it: keyCode plus the `.function`/`.numericPad` pair every
    /// arrow keyDown actually carries (a bare-modifier fake is a keystroke macOS never sends).
    private func arrow(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }
    private static let leftKey: UInt16 = 123
    private static let upKey: UInt16 = 126

    func test_leftAtLeftmostSegment_exitsToNav_withoutChangingTheValue() {
        let notifications = mountSegments()[0]
        var exited = 0
        section?.onExitToNav = { exited += 1 }

        hostWindow?.makeFirstResponder(notifications)
        notifications.keyDown(with: arrow(Self.leftKey))  // On is leftmost — nothing left to cycle

        XCTAssertEqual(exited, 1, "Left at the leftmost segment returns to the nav")
        XCTAssertEqual(notifications.selectedIndex, 0, "exiting must not flip the toggle")
    }

    func test_leftAtNonLeftmostSegment_cycles_ratherThanExiting() {
        let notifications = mountSegments()[0]
        var exited = 0
        section?.onExitToNav = { exited += 1 }
        notifications.select(1)  // Off — now there's a segment to the left

        hostWindow?.makeFirstResponder(notifications)
        notifications.keyDown(with: arrow(Self.leftKey))

        XCTAssertEqual(notifications.selectedIndex, 0, "Left off a non-leftmost segment cycles left")
        XCTAssertEqual(exited, 0, "cycling within the control must not exit to the nav")
    }

    func test_upFromFirstStop_exitsToNav() {
        let notifications = mountSegments()[0]  // the first vertical stop in the section
        var exited = 0
        section?.onExitToNav = { exited += 1 }

        hostWindow?.makeFirstResponder(notifications)
        notifications.keyDown(with: arrow(Self.upKey))

        XCTAssertEqual(exited, 1, "Up from the first stop returns to the nav instead of dead-ending")
    }
}
