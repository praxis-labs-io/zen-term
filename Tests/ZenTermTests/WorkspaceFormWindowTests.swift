import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WorkspaceFormWindowTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-form-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        ConfigLoader.defaultRootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        controller = c
        return c
    }

    private final class Sink {
        var submitted: [Workspace] = []
    }

    private func presentForm(in c: WindowController, sink: Sink) -> WorkspaceFormOverlay {
        let form = WorkspaceFormOverlay(
            existingTitles: [], background: Theme.current.chrome.background.nsColor,
            onSubmit: { sink.submitted.append($0) }, onCancel: {})
        c.presentModalForTesting(form)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return form
    }

    private func interceptor(for c: WindowController) -> KeyInterceptor {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.passThroughGuard = { chord, _ in c.modalOwns(chord) }
        keys.onReservedChord = { c.handle($0) }
        return keys
    }

    private func key(
        _ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags, in c: WindowController
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeFolder(named name: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent("folders", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_tabShortcuts_reachTheFormThroughTheWindow_andLeaveTheWindowsTabsAlone() throws {
        let c = makeWindow()
        let form = presentForm(in: c, sink: Sink())
        let keys = interceptor(for: c)
        let windowTabs = c.tabOrderForTesting

        XCTAssertNil(keys.route(try key(17, "t", flags: [.command], in: c)))
        XCTAssertEqual(form.tabStripForTesting.chips.count, 2, "⌘T adds a tab to the form")

        XCTAssertNil(keys.route(try key(33, "[", flags: [.command, .option], in: c)))
        XCTAssertEqual(form.formForTesting.selected, 0, "⌘⌥[ moves the new tab left")

        XCTAssertNil(keys.route(try key(13, "w", flags: [.command, .option], in: c)))
        XCTAssertEqual(form.tabStripForTesting.chips.count, 1, "⌘⌥W removes it")

        XCTAssertEqual(c.tabOrderForTesting, windowTabs)
        XCTAssertTrue(c.isModalOverlayOpen)
    }

    func test_commandReturn_savesWithAChipFocused() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = presentForm(in: c, sink: sink)
        let folder = try makeFolder(named: "site")
        form.folderFieldForTesting.setText(folder.path)
        form.folderFieldForTesting.field.onChange?()
        form.tabStripForTesting.focusSelectedChip()
        XCTAssertIdentical(c.window.firstResponder, form.tabStripForTesting.chips[0])
        let event = try key(36, "\r", flags: [.command], in: c)

        XCTAssertIdentical(interceptor(for: c).route(event), event, "the form claims ⌘↩ over fill screen")
        XCTAssertTrue(c.window.performKeyEquivalent(with: event))

        XCTAssertEqual(sink.submitted.map(\.title), ["site"])
    }

    func test_commandL_reachesTheFormEvenWhenBoundElsewhere() throws {
        let c = makeWindow()
        let form = presentForm(in: c, sink: Sink())
        let keys = interceptor(for: c)
        var map = KeymapDefaults.map
        map[Chord(command: true, key: "l")] = .clearScreen
        keys.setKeymap(map)
        var fired: [KeyInterceptor.ReservedChord] = []
        keys.onReservedChord = { fired.append($0) }
        form.drawingForTesting.rail(.bottom)?.onOpen?()
        let editor = try XCTUnwrap(c.window.firstResponder as? NSTextView)
        editor.insertText("npm run dev", replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = try key(37, "l", flags: [.command], in: c)

        XCTAssertIdentical(keys.route(event), event)
        XCTAssertTrue(c.window.performKeyEquivalent(with: event))

        XCTAssertEqual(fired, [])
        XCTAssertEqual(form.formForTesting.launchFocus, Workspace.LaunchFocus(tab: 0, region: .bottom))
    }

    func test_addingFromSettings_opensAndSelectsTheWorkspace() throws {
        let c = makeWindow()
        let folder = try makeFolder(named: "zen-term")
        c.handle(.openSettings)
        let settings = try XCTUnwrap(
            descendants(of: c.window.contentView!).compactMap { $0 as? SettingsOverlay }.first)
        let nav = try XCTUnwrap(
            descendants(of: settings).compactMap { $0 as? SettingsNavRow }.first { $0.titleForTesting == "Workspaces" })
        _ = nav.accessibilityPerformPress()
        waitUntil(
            descendants(of: settings).contains { ($0 as? AppButton)?.title == "＋ Add workspace" },
            "the workspaces section to load")
        let add = try XCTUnwrap(
            descendants(of: settings).compactMap { $0 as? AppButton }.first { $0.title == "＋ Add workspace" })

        add.onTap()
        waitUntil(
            descendants(of: c.window.contentView!).contains { $0 is WorkspaceFormOverlay },
            "the workspace form to open")
        let form = try XCTUnwrap(
            descendants(of: c.window.contentView!).compactMap { $0 as? WorkspaceFormOverlay }.first)
        form.folderFieldForTesting.setText(folder.path)
        form.folderFieldForTesting.field.onChange?()
        try XCTUnwrap(descendants(of: form).compactMap { $0 as? AppButton }.first { $0.title == "Add Workspace" })
            .onTap()

        waitUntil(c.workspaceNamesForTesting.contains("zen-term"), "the new workspace to open")
        let index = try XCTUnwrap(c.workspaceNamesForTesting.firstIndex(of: "zen-term"))
        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting[index])
        XCTAssertFalse(c.isModalOverlayOpen)
    }
}
