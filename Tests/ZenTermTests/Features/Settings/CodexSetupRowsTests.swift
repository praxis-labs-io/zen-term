import AppKit
import XCTest

@testable import AgentSetup
@testable import ZenTerm

final class CodexSetupRowsTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?
    private let files = CodexSetupFiles(
        skill: Data("skill".utf8), hook: Data("hook".utf8),
        shippedDigests: [CodexSetupFiles.digest(of: Data("older".utf8)), CodexSetupFiles.digest(of: Data("hook".utf8))])

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-codex-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        CodexAgentSetup.configRootOverrideForTesting = codexRoot
        CodexAgentSetup.filesOverrideForTesting = files
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigReset.toBuiltIn()
        CodexAgentSetup.filesOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private var codexRoot: URL { tempRoot.appendingPathComponent("codex") }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mount() {
        let section = SettingsGeneralSection()
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        hostWindow = window
    }

    private func setupControl() throws -> SegmentedControl {
        mount()
        let control = try XCTUnwrap(
            section?.controlForTesting(SettingsGeneralSection.codexSetupKey) as? SegmentedControl)
        waitUntil(control.isEnabled, "the Codex setup state to load")
        return control
    }

    private func setupMessage() -> String? {
        section?.rowFor(SettingsGeneralSection.codexSetupKey)?.renderedMessageForTesting
    }

    private var updateRow: LayoutRow? { section?.rowFor(SettingsGeneralSection.codexUpdateKey) }

    private func updateButton() throws -> AppButton {
        try XCTUnwrap(section?.controlForTesting(SettingsGeneralSection.codexUpdateKey) as? AppButton)
    }

    private func updateRowTexts() -> [String] {
        updateRow.map { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? []
    }

    private func installedSkill() throws -> Data {
        try Data(contentsOf: codexRoot.appendingPathComponent("skills/zen/SKILL.md"))
    }

    private func press(_ keyCode: UInt16, on control: SegmentedControl) {
        hostWindow?.makeFirstResponder(control)
        control.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode)!)
        waitUntil(control.isEnabled, "the Codex setup change to land")
    }

    private func clickUpdate() throws {
        let update = try updateButton()
        update.performClick(nil)
        waitUntil(update.isHidden && update.isEnabled, "the update to land")
    }

    private static let leftKey: UInt16 = 123
    private static let rightKey: UInt16 = 124

    func test_showsOffWhenNothingIsInstalled() throws {
        let control = try setupControl()

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertNil(setupMessage())
        XCTAssertEqual(updateRow?.isHidden, true)
    }

    func test_namesTheFolderItInstallsTo() throws {
        _ = try setupControl()
        let detail = try XCTUnwrap(hostWindow?.contentView)

        let texts = descendants(of: detail).compactMap { ($0 as? NSTextField)?.stringValue }

        XCTAssertTrue(texts.contains("Teach Codex to use zen"), "\(texts)")
        XCTAssertTrue(
            texts.contains(
                "The zen skill and a hook Codex asks to trust, in \(PathDisplay.abbreviatingHome(codexRoot.path))"),
            "\(texts)")
    }

    func test_choosingOnInstalls_andOffRemoves() throws {
        let control = try setupControl()

        press(Self.leftKey, on: control)

        XCTAssertEqual(control.selectedIndex, 0)
        XCTAssertEqual(try installedSkill(), files.skill)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexRoot.appendingPathComponent("hooks.json").path))
        XCTAssertEqual(updateRow?.isHidden, true)

        press(Self.rightKey, on: control)

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: codexRoot.appendingPathComponent("skills/zen/SKILL.md").path))
    }

    func test_anOlderInstallIsUpdatedByUpdate() throws {
        _ = try CodexSetup(configRoot: codexRoot, files: CodexSetupFiles(skill: Data("older".utf8), hook: files.hook))
            .install()
        _ = try setupControl()

        XCTAssertEqual(updateRow?.isHidden, false)
        XCTAssertTrue(updateRowTexts().contains("Update zen for Codex"), "\(updateRowTexts())")
        XCTAssertTrue(updateRowTexts().contains("An older version is installed."))

        try clickUpdate()

        XCTAssertEqual(updateRow?.isHidden, true)
        XCTAssertEqual(try installedSkill(), files.skill)
    }

    func test_anEditedInstallIsReplacedByUpdate() throws {
        _ = try CodexSetup(configRoot: codexRoot, files: CodexSetupFiles(skill: Data("mine".utf8), hook: files.hook))
            .install()
        let control = try setupControl()

        XCTAssertTrue(updateRowTexts().contains("Your zen setup has changes, and updating replaces them."))

        try clickUpdate()

        XCTAssertEqual(control.selectedIndex, 0)
        XCTAssertEqual(try installedSkill(), files.skill)
    }

    func test_malformedHooksFileShowsWhy_andWritesNothing() throws {
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: codexRoot.appendingPathComponent("hooks.json"))
        let control = try setupControl()

        press(Self.leftKey, on: control)

        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertTrue(setupMessage()?.contains("hooks.json") == true, "got: \(setupMessage() ?? "nil")")
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexRoot.appendingPathComponent("skills").path))
    }
}
