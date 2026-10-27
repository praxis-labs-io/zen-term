import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ModalSubmitKeyWindowTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
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

    private func present(_ overlay: ModalOverlay, in c: WindowController) {
        c.presentModalForTesting(overlay)
        c.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func field(_ overlay: NSView, placeholder: String) throws -> FieldBox {
        try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? FieldBox }.first { $0.placeholder == placeholder })
    }

    private func press(_ code: UInt16, flags: NSEvent.ModifierFlags, in c: WindowController) throws -> Bool {
        let keys = KeyInterceptor()
        keys.setKeymap(KeymapDefaults.map)
        keys.passThroughGuard = { c.passesThrough($0, as: $1, firstResponder: c.window.firstResponder) }
        keys.onReservedChord = { c.handle($0) }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: c.window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        guard let routed = keys.route(event) else { return false }
        return c.window.performKeyEquivalent(with: routed)
    }

    func test_commandReturn_submitsReportIssueFromTheTitleField() throws {
        let c = makeWindow()
        var opened: [URL] = []
        let report = SystemReport(appVersion: "0.3.0", build: "1", osVersion: "15.5", architecture: "arm64")
        let form = ReportIssueOverlay(
            report: report, onOpenURL: { opened.append($0) }, onExportDiagnostics: {}, onCancel: {})
        present(form, in: c)
        let title = try field(form, placeholder: "A short summary")
        title.setText("Split closes the pane")
        try XCTUnwrap(descendants(of: form).compactMap { $0 as? TextAreaBox }.first).setText("It closed the pane")
        XCTAssertTrue(KeyboardFocus.isFocused(title.field, in: c.window), "the title field has focus")

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(opened.count, 1)
    }

    func test_commandReturn_submitsNewWorktreeFromTheBranchField() throws {
        let c = makeWindow()
        var submitted: [NewWorktreeOverlay.Request] = []
        let workspace = Workspace(
            title: "ZenTerm", path: URL(fileURLWithPath: "/tmp/zenterm-fixture"), tabs: [], env: [:], carry: [])
        let form = NewWorktreeOverlay(
            workspace: workspace,
            options: WorktreeStore.CreateOptions(
                branches: [], defaultBase: "origin/main", currentBranch: "main", holders: [:]),
            onSubmit: { submitted.append($0) }, onCancel: {}, onDismiss: {})
        present(form, in: c)
        let branch = try field(form, placeholder: "feature/name")
        branch.setText("feature/zen-671")
        branch.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: branch.field))
        XCTAssertTrue(KeyboardFocus.isFocused(branch.field, in: c.window), "the branch field has focus")

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(submitted.count, 1)
    }

    func test_commandReturn_submitsToolFloatFromTheTitleField() throws {
        let c = makeWindow()
        var submitted: [ToolFloat] = []
        let existing = ToolFloat(
            id: "scratch-pad", order: 1, title: "Scratch pad", icon: ToolFloatParser.defaultIcon,
            command: "vim", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
            requiresGitRepo: false, persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "l"))
        let form = ToolFloatFormOverlay(
            editing: existing, existingIDs: [], capturer: nil,
            onSubmit: {
                submitted.append($0)
                return nil
            }, onCancel: {}, onDismiss: {})
        present(form, in: c)
        let title = try field(form, placeholder: "Open GitDash")
        XCTAssertTrue(KeyboardFocus.isFocused(title.field, in: c.window), "the title field has focus")

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(submitted.count, 1)
    }

    func test_return_submitsAddSSHHostFromTheHostField() throws {
        let c = makeWindow()
        var submitted: [SSHHostEntry] = []
        let form = AddSSHHostOverlay(
            mode: .add(taken: []), removal: nil,
            onSubmit: {
                submitted.append($0)
                return nil
            }, onCancel: {}, onDismiss: {})
        present(form, in: c)
        let host = try XCTUnwrap(descendants(of: form).compactMap { $0 as? FieldBox }.first)
        host.setText("deploy@10.0.0.5")
        XCTAssertTrue(KeyboardFocus.isFocused(host.field, in: c.window), "the host field has focus")

        XCTAssertTrue(try press(36, flags: [], in: c))

        XCTAssertEqual(submitted, [SSHHostEntry(alias: "deploy@10.0.0.5")])
    }
}
