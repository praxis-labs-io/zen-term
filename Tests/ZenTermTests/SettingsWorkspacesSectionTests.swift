import AppKit
import XCTest

@testable import ZenTerm

final class SettingsWorkspacesSectionTests: WindowTestCase {
    private final class EditSink {
        var calls: [Workspace?] = []
    }

    private var tempRoot: URL!
    private var window: NSWindow?
    private var section: SettingsWorkspacesSection?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-workspaces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        GitRepoStatus.resetForTesting()
    }

    override func tearDownWithError() throws {
        window = nil
        section = nil
        GitRepoStatus.resetForTesting()
        ConfigLoader.defaultRootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @discardableResult
    private func mount(_ section: SettingsWorkspacesSection, waitingForLoad: Bool = true) -> NSView {
        self.section = section
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
        if waitingForLoad { waitForLoad(in: detail) }
        return detail
    }

    private func waitForLoad(in detail: NSView) {
        waitUntil(
            !rows(in: detail).isEmpty || emptyHint(in: detail) != nil,
            "the workspaces section to finish loading")
    }

    private func emptyHint(in view: NSView) -> NSTextField? {
        descendants(of: view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("No workspaces yet") }
    }

    private func rows(in view: NSView) -> [WorkspaceRow] {
        descendants(of: view).compactMap { $0 as? WorkspaceRow }
    }

    private let twoWorkspaces = """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        main = nvim
        """

    func test_rendersRowPerConfiguredWorkspace() throws {
        try seed(twoWorkspaces)
        let detail = mount(SettingsWorkspacesSection())
        XCTAssertEqual(rows(in: detail).map(\.workspace.title), ["Alpha", "Beta"])
    }

    func test_emptyConfig_showsOnlyAddButtonStop() throws {
        try seed("")
        let section = SettingsWorkspacesSection()
        let detail = mount(section)
        XCTAssertTrue(rows(in: detail).isEmpty)
        XCTAssertEqual(section.detailStops().count, 1, "empty state exposes only the add button")
        XCTAssertTrue(section.detailStops().first is AppButton)
    }

    func test_addButton_invokesOnEditWorkspaceWithNil() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        let sink = EditSink()
        section.onEditWorkspace = { sink.calls.append($0) }
        _ = mount(section)

        (section.detailStops().last as? AppButton)?.onTap()

        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertNil(sink.calls.first ?? nil, "the add button adds a new workspace (nil)")
    }

    func test_row_buildsWithItsBadgeHidden_whenNothingHasProbedTheFolder() {
        let row = WorkspaceRow(
            workspace: Workspace(
                title: "Repo", path: tempRoot, main: nil, right: nil, bottom: nil, focus: .main, env: [:]))
        let badge = descendants(of: row).compactMap { $0 as? NSImageView }.first
        XCTAssertEqual(badge?.isHidden, true, "nothing has probed the folder yet")
    }

    func test_gitRepoWorkspace_showsGitBadge_plainDoesNot() throws {
        let repo = tempRoot.appendingPathComponent("repo", isDirectory: true)
        let plain = tempRoot.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".git"))
        try seed("[Repo]\npath = \(repo.path)\n\n[Plain]\npath = \(plain.path)\n")
        let detail = mount(SettingsWorkspacesSection())

        func badge(inRowTitled title: String) -> NSImageView? {
            let row = rows(in: detail).first { $0.workspace.title == title }!
            return descendants(of: row).compactMap { $0 as? NSImageView }.first
        }
        waitUntil(badge(inRowTitled: "Repo")?.isHidden == false, "the repo's git badge to land")
        waitUntil(GitRepoStatus.known(plain) != nil, "the plain folder to be answered too")

        XCTAssertNotNil(
            badge(inRowTitled: "Repo")?.image, "the badge renders the bundled git logo, not an empty view")
        XCTAssertEqual(badge(inRowTitled: "Plain")?.isHidden, true, "a plain folder keeps its badge hidden")
    }

    func test_whileLoading_showsNeitherRowsNorTheEmptyStateHint() throws {
        try seed(twoWorkspaces)

        let detail = mount(SettingsWorkspacesSection(), waitingForLoad: false)

        XCTAssertTrue(rows(in: detail).isEmpty, "no rows before the file has been read")
        XCTAssertNil(emptyHint(in: detail), "and no 'no workspaces yet' hint for a file that has two")

        waitForLoad(in: detail)
        XCTAssertEqual(rows(in: detail).count, 2)
        XCTAssertNil(emptyHint(in: detail))
    }

    func test_focusSurvivesTheRowsLanding() throws {
        try seed(twoWorkspaces)
        let detail = mount(SettingsWorkspacesSection(), waitingForLoad: false)
        let window = try XCTUnwrap(self.window)
        let section = try XCTUnwrap(self.section)
        let addButton = try XCTUnwrap(section.detailStops().first)
        XCTAssertTrue(window.makeFirstResponder(addButton))

        waitForLoad(in: detail)

        XCTAssertTrue(
            window.firstResponder === addButton,
            "the rows arriving must not move focus off the button the user was on: Return there adds "
                + "a workspace, and on a row it opens one")
    }

    func test_rowActivate_invokesOnEditWorkspaceWithThatWorkspace() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        let sink = EditSink()
        section.onEditWorkspace = { sink.calls.append($0) }
        let detail = mount(section)

        rows(in: detail).first { $0.workspace.title == "Beta" }?.onActivate?()

        XCTAssertEqual(sink.calls.first??.title, "Beta")
    }

    private func arrow(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers.union([.function, .numericPad]),
            timestamp: 0, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    private var optionDown: NSEvent { arrow(125, .option) }
    private var optionUp: NSEvent { arrow(126, .option) }

    private func settleReorder() {
        let done = expectation(description: "reorder applied")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func wireReorder(_ section: SettingsWorkspacesSection) {
        section.onReorder = { moved, neighbour in
            (try? WorkspacesWriter.swap(moved.title, with: neighbour.title)) ?? false
        }
    }

    private func configuredTitles() -> [String] {
        ConfigLoader.loadWorkspacesBlocking(configRoot: tempRoot).map(\.title)
    }

    func test_optionDown_movesWorkspaceDown_andPersists() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).first?.keyDown(with: optionDown)
        settleReorder()

        XCTAssertEqual(configuredTitles(), ["Beta", "Alpha"], "the file carries the new order")
        XCTAssertEqual(rows(in: detail).map(\.workspace.title), ["Beta", "Alpha"], "and so does the list")
    }

    func test_optionUp_movesWorkspaceUp_andPersists() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).last?.keyDown(with: optionUp)
        settleReorder()

        XCTAssertEqual(configuredTitles(), ["Beta", "Alpha"])
    }

    func test_reorder_keepsFocusOnTheMovedRow() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        wireReorder(section)
        let detail = mount(section)
        let window = try XCTUnwrap(self.window)
        let first = try XCTUnwrap(rows(in: detail).first)
        XCTAssertTrue(window.makeFirstResponder(first))

        first.keyDown(with: optionDown)
        settleReorder()

        let focused = window.firstResponder as? WorkspaceRow
        XCTAssertEqual(focused?.workspace.title, "Alpha", "focus follows the workspace that moved")
    }

    func test_optionDown_atTheEnd_doesNothing() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).last?.keyDown(with: optionDown)
        settleReorder()

        XCTAssertEqual(configuredTitles(), ["Alpha", "Beta"])
    }

    func test_plainArrow_movesFocus_withoutReordering() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        wireReorder(section)
        let detail = mount(section)
        let window = try XCTUnwrap(self.window)
        let first = try XCTUnwrap(rows(in: detail).first)
        XCTAssertTrue(window.makeFirstResponder(first))

        first.keyDown(with: arrow(125))
        settleReorder()

        XCTAssertEqual(configuredTitles(), ["Alpha", "Beta"], "nothing was reordered")
        XCTAssertEqual(
            (window.firstResponder as? WorkspaceRow)?.workspace.title, "Beta", "it moves focus instead")
    }

    func test_optionCommandArrow_doesNotReorder() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        wireReorder(section)
        let detail = mount(section)

        rows(in: detail).first?.keyDown(with: arrow(125, [.option, .command]))
        settleReorder()

        XCTAssertEqual(configuredTitles(), ["Alpha", "Beta"])
    }

    func test_staleRow_whoseSectionIsGoneFromTheFile_leavesTheListAlone() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        wireReorder(section)
        let detail = mount(section)
        try seed("[Alpha]\npath = ~/Dev/alpha\n")

        rows(in: detail).first?.keyDown(with: optionDown)
        settleReorder()

        XCTAssertEqual(rows(in: detail).map(\.workspace.title), ["Alpha", "Beta"], "the list holds still")
        XCTAssertEqual(configuredTitles(), ["Alpha"], "and the file is untouched")
    }

    func test_failedWrite_leavesTheListAlone() throws {
        try seed(twoWorkspaces)
        let section = SettingsWorkspacesSection()
        section.onReorder = { _, _ in false }
        let detail = mount(section)

        rows(in: detail).first?.keyDown(with: optionDown)
        settleReorder()

        XCTAssertEqual(rows(in: detail).map(\.workspace.title), ["Alpha", "Beta"])
    }

    func test_reorderHint_shownOnlyWhenThereIsSomethingToReorder() throws {
        func hint(in view: NSView) -> NSTextField? {
            descendants(of: view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue.contains("to reorder") }
        }

        try seed(twoWorkspaces)
        XCTAssertNotNil(hint(in: mount(SettingsWorkspacesSection())), "two workspaces can be reordered")

        try seed("[Solo]\npath = ~/Dev/solo\n")
        XCTAssertNil(hint(in: mount(SettingsWorkspacesSection())), "one workspace cannot")
    }
}
