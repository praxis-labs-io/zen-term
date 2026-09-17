import AppKit
import XCTest

@testable import ZenTerm

final class SettingsGeneralSectionTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-general-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigReset.toBuiltIn()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

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
        segment(.notifications).select(1)

        XCTAssertTrue(
            configText().contains("agent-notifications = false"), "got: \(configText())")
    }

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

        updates.select(1)
        XCTAssertTrue(
            configText().contains("automatic-update-checks = false"), "got: \(configText())")

        updates.select(0)
        XCTAssertTrue(
            configText().contains("automatic-update-checks = true"), "got: \(configText())")
    }

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
        notifications.keyDown(with: arrow(Self.leftKey))

        XCTAssertEqual(exited, 1, "Left at the leftmost segment returns to the nav")
        XCTAssertEqual(notifications.selectedIndex, 0, "exiting must not flip the toggle")
    }

    func test_leftAtNonLeftmostSegment_cycles_ratherThanExiting() {
        let notifications = mountSegments()[0]
        var exited = 0
        section?.onExitToNav = { exited += 1 }
        notifications.select(1)

        hostWindow?.makeFirstResponder(notifications)
        notifications.keyDown(with: arrow(Self.leftKey))

        XCTAssertEqual(notifications.selectedIndex, 0, "Left off a non-leftmost segment cycles left")
        XCTAssertEqual(exited, 0, "cycling within the control must not exit to the nav")
    }

    func test_upFromFirstStop_staysPut() {
        let notifications = mountSegments()[0]
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
