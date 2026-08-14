import AppKit
import XCTest

@testable import ZenTerm

/// Interaction test for the General settings section: mount the real section in a window, drive its
/// On/Off segmented controls the way a click would, and assert the value that actually lands in the
/// config file. A state-only assertion would pass while the control is dead — exactly how a broken
/// dropdown once shipped past two reviews — so this drives the controls themselves. Notifications
/// and Updates share this section, so both toggles are exercised here.
///
/// The write→reload pipeline is rooted at `ConfigLoader.defaultRoot`; the test points that at a temp
/// dir via `defaultRootOverrideForTesting` so it never touches the real config.
final class SettingsGeneralSectionTests: WindowTestCase {
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

    /// Mount the section (section + window retained) and return its segmented controls in
    /// `populate()` order, which `Segment` names.
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

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    /// The segmented rows the section builds, in the order `populate()` adds them. Named rather
    /// than indexed inline: a row added in the middle silently re-points every bare number.
    private enum Segment: Int {
        case notifications, attentionToast, completionToast, updates
    }

    private func segment(_ which: Segment) -> SegmentedControl {
        mountSegments()[which.rawValue]
    }

    func test_everyToggle_isPresent_andDefaults() {
        let segments = mountSegments()
        XCTAssertEqual(segments.count, 4, "notifications, the two toast rows, and updates")
        XCTAssertEqual(segments[Segment.notifications.rawValue].selectedIndex, 0, "notifications On")
        XCTAssertEqual(segments[Segment.attentionToast.rawValue].selectedIndex, 0, "attention Sticky")
        XCTAssertEqual(segments[Segment.completionToast.rawValue].selectedIndex, 0, "completion Sticky")
        XCTAssertEqual(segments[Segment.updates.rawValue].selectedIndex, 0, "automatic updates On")
    }

    func test_notifications_selectingOff_writesFalse() {
        segment(.notifications).select(1)  // drive the Off segment as a click would

        XCTAssertTrue(
            configText().contains("agent-notifications = false"), "got: \(configText())")
    }

    /// The two toast rows share a parse helper and a token function, so each has to prove it writes
    /// its own key: a copy-paste that pointed both at `attention-toast` would leave the completion
    /// row silently editing the wrong setting.
    func test_attentionToast_selectingAuto_writesItsOwnKey() {
        segment(.attentionToast).select(1)

        XCTAssertTrue(configText().contains("attention-toast = auto"), "got: \(configText())")
        XCTAssertFalse(configText().contains("completion-toast"), "got: \(configText())")
    }

    func test_completionToast_selectingAuto_writesItsOwnKey() {
        segment(.completionToast).select(1)

        XCTAssertTrue(configText().contains("completion-toast = auto"), "got: \(configText())")
        XCTAssertFalse(configText().contains("attention-toast"), "got: \(configText())")
    }

    func test_updates_selectingOff_thenOn_writesFalseThenTrue() {
        let updates = segment(.updates)

        updates.select(1)  // Off
        XCTAssertTrue(
            configText().contains("automatic-update-checks = false"), "got: \(configText())")

        updates.select(0)  // back to On
        XCTAssertTrue(
            configText().contains("automatic-update-checks = true"), "got: \(configText())")
    }

    // MARK: back to the nav — a section of stacked segmented rows had no arrow path out

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

    /// Up at the first stop holds, the way it does in Shortcuts, Tools and Workspaces. It used to
    /// exit here, back when a segmented first row had no other way out; Left at the leftmost segment is
    /// that way out now (see the test above), so the extra path only made this section lose your place
    /// where the list sections keep it.
    func test_upFromFirstStop_staysPut() {
        let notifications = mountSegments()[0]  // the first vertical stop in the section
        var exited = 0
        section?.onExitToNav = { exited += 1 }

        hostWindow?.makeFirstResponder(notifications)
        notifications.keyDown(with: arrow(Self.upKey))

        XCTAssertEqual(exited, 0, "Up at the top of a section is a no-op, not a trip back to the nav")
        XCTAssertTrue(
            KeyboardFocus.isFocused(notifications, in: hostWindow),
            "and focus stays on the row it was on")
    }
}
