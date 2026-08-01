import AppKit
import XCTest

@testable import ZenTerm

/// End-to-end tests for the Appearance "Toolbar buttons" multi-select (ZEN-327): mount the real
/// section over a sandboxed config root, drive the real checkbox list, and read the file it wrote —
/// the full write path a user's click takes, not the closure in isolation.
final class SettingsToolbarButtonsRowTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-toolbar-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()  // restore the process's real config state
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func configText() -> String {
        (try? String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    /// Mount the Appearance section in a host window and return its toolbar checkbox list.
    private func mountToolbarList() throws -> CheckboxList {
        let section = SettingsAppearanceSection()
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow = window
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let list = try XCTUnwrap(
            descendants(of: detail).compactMap { $0 as? CheckboxList }.first,
            "the Appearance section should mount the toolbar multi-select")
        window.makeFirstResponder(list)
        return list
    }

    private func pressSpace(_ list: CheckboxList) {
        list.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                keyCode: 49)!)
    }

    func test_uncheckingWritesTheHideList_andRecheckingRemovesTheKey() throws {
        let list = try mountToolbarList()
        XCTAssertEqual(list.itemsForTesting.count, ToolbarButton.allCases.count)
        XCTAssertTrue(list.itemsForTesting.allSatisfy(\.isChecked), "everything shows by default")

        pressSpace(list)  // uncheck New tab (the first, highlighted row)

        XCTAssertTrue(
            configText().contains("hide-toolbar-buttons = new-tab"),
            "unchecking a button must write the hide list; file was: \(configText())")
        XCTAssertEqual(
            list.itemsForTesting.first?.isChecked, false,
            "the row must re-render from the reloaded config")
        XCTAssertEqual(GeneralConfig.current.hiddenToolbarButtons, [.newTab])

        pressSpace(list)  // re-check it — nothing hidden, so the key must go, not linger empty

        XCTAssertFalse(configText().contains("hide-toolbar-buttons"))
        XCTAssertEqual(list.itemsForTesting.first?.isChecked, true)
        XCTAssertEqual(GeneralConfig.current.hiddenToolbarButtons, [])
    }
}
