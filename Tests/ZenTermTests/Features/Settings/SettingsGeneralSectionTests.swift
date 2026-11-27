import AppKit
import XCTest

@testable import AgentSetup
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
        ClaudeCodeSetup.configRootOverrideForTesting = tempRoot.appendingPathComponent("claude")
        ClaudeCodeSetup.filesOverrideForTesting = ClaudeSetupFiles(
            skill: Data("skill".utf8), hook: Data("hook".utf8),
            shippedDigests: [
                ClaudeSetupFiles.digest(of: Data("older".utf8)), ClaudeSetupFiles.digest(of: Data("hook".utf8)),
            ])
        PiCodingAgentSetup.configRootOverrideForTesting = tempRoot.appendingPathComponent("pi")
        PiCodingAgentSetup.filesOverrideForTesting = PiSetupFiles(
            skill: Data("skill".utf8), extension: Data("extension".utf8),
            shippedDigests: [
                PiSetupFiles.digest(of: Data("older".utf8)), PiSetupFiles.digest(of: Data("extension".utf8)),
            ])
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigReset.toBuiltIn()
        ClaudeCodeSetup.configRootOverrideForTesting = nil
        ClaudeCodeSetup.filesOverrideForTesting = nil
        PiCodingAgentSetup.configRootOverrideForTesting = nil
        PiCodingAgentSetup.filesOverrideForTesting = nil
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
        case notifications, claudeSetup, piSetup, attentionToast, completionToast, updates
    }

    private func segment(_ which: Segment) -> SegmentedControl {
        mountSegments()[which.rawValue]
    }

    func test_everyToggle_isPresent_andDefaults() {
        let segments = mountSegments()
        XCTAssertEqual(segments.count, 6, "notifications, Claude Code and Pi setup, the two toast rows, and updates")
        XCTAssertEqual(segments[Segment.notifications.rawValue].selectedIndex, 0, "notifications On")
        XCTAssertEqual(segments[Segment.attentionToast.rawValue].selectedIndex, 0, "attention Off")
        XCTAssertEqual(segments[Segment.completionToast.rawValue].selectedIndex, 0, "completion Off")
        XCTAssertEqual(segments[Segment.updates.rawValue].selectedIndex, 0, "automatic updates On")
    }

    func test_agentPrograms_typedInTheField_registerAsAgents() throws {
        _ = mountSegments()
        let field = try XCTUnwrap(section?.controlForTesting("agents") as? FieldBox)

        field.setText("Pi, gemini")
        field.onChange?()
        field.onEndEditing?()

        XCTAssertEqual(GeneralConfig.current.listedAgents, ["pi", "gemini"])
        XCTAssertEqual(AgentRoster.agentName(launching: "gemini", listed: GeneralConfig.current.listedAgents), "gemini")
    }

    func test_notifications_selectingOff_writesFalse() {
        segment(.notifications).select(1)

        XCTAssertTrue(
            configText().contains("agent-notifications = false"), "got: \(configText())")
    }

    func test_toastRows_offerOffStickyAndAuto() {
        let segments = mountSegments()
        for row in [Segment.attentionToast, .completionToast] {
            XCTAssertEqual(segments[row.rawValue].optionTitles, ["Off", "Sticky", "Auto"], "\(row)")
        }
    }

    func test_attentionToast_writesEachValue_toItsOwnKey() {
        assertWritesEachDismissal(.attentionToast, key: "attention-toast", other: "completion-toast")
    }

    func test_completionToast_writesEachValue_toItsOwnKey() {
        assertWritesEachDismissal(.completionToast, key: "completion-toast", other: "attention-toast")
    }

    private func assertWritesEachDismissal(
        _ row: Segment, key: String, other: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let control = segment(row)
        for (index, value) in [(1, "sticky"), (2, "auto"), (0, "off")] {
            control.select(index)
            XCTAssertTrue(configText().contains("\(key) = \(value)"), "got: \(configText())", file: file, line: line)
            XCTAssertFalse(configText().contains(other), "got: \(configText())", file: file, line: line)
        }
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

    private var claudeRoot: URL { tempRoot.appendingPathComponent("claude") }

    private func claudeSetupControl() -> SegmentedControl {
        let control = segment(.claudeSetup)
        waitUntil(control.isEnabled, "the Claude Code setup state to load")
        return control
    }

    private func claudeSetupMessage() -> String? {
        section?.rowFor(SettingsGeneralSection.claudeSetupKey)?.renderedMessageForTesting
    }

    private func press(_ keyCode: UInt16, on control: SegmentedControl) {
        hostWindow?.makeFirstResponder(control)
        control.keyDown(with: arrow(keyCode))
        waitUntil(control.isEnabled, "the Claude Code setup change to land")
    }

    func test_claudeSetup_showsOffWhenNothingIsInstalled() {
        let control = claudeSetupControl()

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertNil(claudeSetupMessage())
    }

    func test_claudeSetup_namesTheFolderItInstallsTo() throws {
        _ = claudeSetupControl()
        let detail = try XCTUnwrap(hostWindow?.contentView)

        let texts = descendants(of: detail).compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(
            texts.contains("The zen skill and a session hook, in \(PathDisplay.abbreviatingHome(claudeRoot.path))"),
            "\(texts)")
    }

    func test_claudeSetup_choosingOnInstalls_andOffRemoves() {
        let control = claudeSetupControl()

        press(Self.leftKey, on: control)

        XCTAssertEqual(control.selectedIndex, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: claudeRoot.appendingPathComponent("skills/zen/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeRoot.appendingPathComponent("settings.json").path))

        press(Self.rightKey, on: control)

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: claudeRoot.appendingPathComponent("skills/zen/SKILL.md").path))
    }

    private func updateButton() throws -> AppButton {
        let detail = try XCTUnwrap(hostWindow?.contentView)
        return try XCTUnwrap(descendants(of: detail).compactMap { $0 as? AppButton }.first { $0.title == "Update" })
    }

    private var updateRow: LayoutRow? { section?.rowFor(SettingsGeneralSection.claudeUpdateKey) }

    private func updateRowTexts() -> [String] {
        updateRow.map { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? []
    }

    private func installedSkill() throws -> Data {
        try Data(contentsOf: claudeRoot.appendingPathComponent("skills/zen/SKILL.md"))
    }

    private func clickUpdate() throws {
        let update = try updateButton()
        update.performClick(nil)
        waitUntil(update.isHidden && update.isEnabled, "the update to land")
    }

    private func installOlder() throws {
        let older = ClaudeSetupFiles(skill: Data("older".utf8), hook: Data("hook".utf8))
        _ = try ClaudeSetup(configRoot: claudeRoot, files: older).install()
    }

    func test_claudeSetup_offersNoUpdateWhenNothingIsInstalledOrItIsCurrent() throws {
        let control = claudeSetupControl()
        XCTAssertEqual(updateRow?.isHidden, true)

        press(Self.leftKey, on: control)

        XCTAssertEqual(control.selectedIndex, 0)
        XCTAssertEqual(updateRow?.isHidden, true)
        XCTAssertTrue(try updateButton().isHidden)
    }

    func test_claudeSetup_anEditedInstallIsReplacedByUpdate() throws {
        _ = try ClaudeSetup(
            configRoot: claudeRoot, files: ClaudeSetupFiles(skill: Data("mine".utf8), hook: Data("hook".utf8))
        )
        .install()
        let control = claudeSetupControl()

        XCTAssertEqual(updateRow?.isHidden, false)
        XCTAssertTrue(updateRowTexts().contains("Your zen setup has changes, and updating replaces them."))

        try clickUpdate()

        XCTAssertEqual(updateRow?.isHidden, true)
        XCTAssertEqual(control.selectedIndex, 0)
        XCTAssertEqual(try installedSkill(), Data("skill".utf8))
    }

    func test_claudeSetup_anOlderInstallIsUpdatedByUpdate() throws {
        try installOlder()
        _ = claudeSetupControl()

        XCTAssertEqual(updateRow?.isHidden, false)
        XCTAssertTrue(updateRowTexts().contains("An older version is installed."))

        try clickUpdate()

        XCTAssertEqual(updateRow?.isHidden, true)
        XCTAssertEqual(try installedSkill(), Data("skill".utf8))
    }

    func test_claudeSetup_tabSkipsTheUpdateRowOnceUpdated() throws {
        try installOlder()
        let control = claudeSetupControl()
        hostWindow?.makeFirstResponder(control)
        control.onTab?()
        XCTAssertTrue(KeyboardFocus.isFocused(try updateButton(), in: hostWindow))

        try clickUpdate()
        hostWindow?.makeFirstResponder(control)
        control.onTab?()

        let detail = try XCTUnwrap(hostWindow?.contentView)
        let next = descendants(of: detail).compactMap { $0 as? SegmentedControl }[Segment.piSetup.rawValue]
        XCTAssertTrue(KeyboardFocus.isFocused(next, in: hostWindow))
    }

    func test_claudeSetup_malformedSettingsShowsWhy_andWritesNothing() throws {
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: claudeRoot.appendingPathComponent("settings.json"))
        let control = claudeSetupControl()

        press(Self.leftKey, on: control)

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertTrue(claudeSetupMessage()?.contains("settings.json") == true, "got: \(claudeSetupMessage() ?? "nil")")
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeRoot.appendingPathComponent("skills").path))
    }

    private var piRoot: URL { tempRoot.appendingPathComponent("pi") }

    private func piSetupControl() -> SegmentedControl {
        let control = segment(.piSetup)
        waitUntil(control.isEnabled, "the Pi setup state to load")
        return control
    }

    private func piUpdateButton() throws -> AppButton {
        let row = try XCTUnwrap(section?.rowFor(SettingsGeneralSection.piUpdateKey))
        return try XCTUnwrap(descendants(of: row).compactMap { $0 as? AppButton }.first)
    }

    private var piUpdateRow: LayoutRow? { section?.rowFor(SettingsGeneralSection.piUpdateKey) }

    private func piInstalledSkill() throws -> Data {
        try Data(contentsOf: piRoot.appendingPathComponent("skills/zen/SKILL.md"))
    }

    func test_piSetup_showsOffWhenNothingIsInstalled_andNamesItsFolder() throws {
        let control = piSetupControl()
        let detail = try XCTUnwrap(hostWindow?.contentView)
        let texts = descendants(of: detail).compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertNil(section?.rowFor(SettingsGeneralSection.piSetupKey)?.renderedMessageForTesting)
        XCTAssertEqual(piUpdateRow?.isHidden, true)
        XCTAssertTrue(
            texts.contains("The zen skill and a session extension, in \(PathDisplay.abbreviatingHome(piRoot.path))"),
            "\(texts)")
    }

    func test_piSetup_choosingOnInstalls_andOffRemoves() {
        let control = piSetupControl()
        let skill = piRoot.appendingPathComponent("skills/zen/SKILL.md")
        let piExtension = piRoot.appendingPathComponent("extensions/zenterm-context.ts")

        press(Self.leftKey, on: control)

        XCTAssertEqual(control.selectedIndex, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: piExtension.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeRoot.path), "Pi's row leaves Claude Code alone")

        press(Self.rightKey, on: control)

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: piExtension.path))
    }

    func test_piSetup_anOlderInstallIsUpdatedByUpdate() throws {
        let older = PiSetupFiles(skill: Data("older".utf8), extension: Data("extension".utf8))
        _ = try PiSetup(configRoot: piRoot, files: older).install()
        _ = piSetupControl()

        XCTAssertEqual(piUpdateRow?.isHidden, false)
        let update = try piUpdateButton()
        update.performClick(nil)
        waitUntil(update.isHidden && update.isEnabled, "the update to land")

        XCTAssertEqual(piUpdateRow?.isHidden, true)
        XCTAssertEqual(try piInstalledSkill(), Data("skill".utf8))
    }

    func test_piSetup_anEditedInstallOffersUpdate() throws {
        _ = try PiSetup(
            configRoot: piRoot, files: PiSetupFiles(skill: Data("mine".utf8), extension: Data("extension".utf8))
        )
        .install()
        _ = piSetupControl()

        let texts = piUpdateRow.map { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? []
        XCTAssertEqual(piUpdateRow?.isHidden, false)
        XCTAssertTrue(texts.contains("Your zen setup has changes, and updating replaces them."))
    }

    private func arrow(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }
    private static let leftKey: UInt16 = 123
    private static let upKey: UInt16 = 126
    private static let rightKey: UInt16 = 124

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
