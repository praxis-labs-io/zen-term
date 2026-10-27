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

    private final class Sink {
        var submitCount = 0
    }

    private func makeReportIssue(_ sink: Sink) throws -> ReportIssueOverlay {
        let report = SystemReport(appVersion: "0.3.0", build: "1", osVersion: "15.5", architecture: "arm64")
        let form = ReportIssueOverlay(
            report: report, onOpenURL: { _ in sink.submitCount += 1 }, onExportDiagnostics: {}, onCancel: {})
        try field(form, placeholder: "A short summary").setText("Split closes the pane")
        try XCTUnwrap(descendants(of: form).compactMap { $0 as? TextAreaBox }.first).setText("It closed the pane")
        return form
    }

    private func makeNewWorktree(_ sink: Sink) throws -> NewWorktreeOverlay {
        let workspace = Workspace(
            title: "ZenTerm", path: URL(fileURLWithPath: "/tmp/zenterm-fixture"), tabs: [], env: [:], carry: [])
        let form = NewWorktreeOverlay(
            workspace: workspace,
            options: WorktreeStore.CreateOptions(
                branches: [], defaultBase: "origin/main", currentBranch: "main", holders: [:]),
            onSubmit: { _ in sink.submitCount += 1 }, onCancel: {}, onDismiss: {})
        let branch = try field(form, placeholder: "feature/name")
        branch.setText("feature/zen-671")
        branch.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: branch.field))
        return form
    }

    private func makeToolFloat(_ sink: Sink) -> ToolFloatFormOverlay {
        let existing = ToolFloat(
            id: "scratch-pad", order: 1, title: "Scratch pad", icon: ToolFloatParser.defaultIcon,
            command: "vim", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
            requiresGitRepo: false, persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "l"))
        return ToolFloatFormOverlay(
            editing: existing, existingIDs: [], capturer: nil,
            onSubmit: { _ in
                sink.submitCount += 1
                return nil
            }, onCancel: {}, onDismiss: {})
    }

    private func makeAddSSHHost(_ sink: Sink) throws -> AddSSHHostOverlay {
        let form = AddSSHHostOverlay(
            mode: .add(taken: []), removal: nil,
            onSubmit: { _ in
                sink.submitCount += 1
                return nil
            }, onCancel: {}, onDismiss: {})
        try XCTUnwrap(descendants(of: form).compactMap { $0 as? FieldBox }.first).setText("deploy@10.0.0.5")
        return form
    }

    private func focus(_ view: NSView, in c: WindowController) {
        XCTAssertTrue(c.window.makeFirstResponder(view))
        XCTAssertTrue(KeyboardFocus.isFocused(view, in: c.window), "the \(type(of: view)) has focus")
    }

    func test_commandReturn_submitsReportIssueFromTheTitleField() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = try makeReportIssue(sink)
        present(form, in: c)
        focus(try field(form, placeholder: "A short summary").field, in: c)

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(sink.submitCount, 1)
    }

    func test_commandReturn_submitsNewWorktreeFromTheBranchField() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = try makeNewWorktree(sink)
        present(form, in: c)
        focus(try field(form, placeholder: "feature/name").field, in: c)

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(sink.submitCount, 1)
    }

    func test_commandReturn_submitsToolFloatFromTheTitleField() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = makeToolFloat(sink)
        present(form, in: c)
        focus(try field(form, placeholder: "Open GitDash").field, in: c)

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(sink.submitCount, 1)
    }

    func test_return_submitsAddSSHHostFromTheHostField() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = try makeAddSSHHost(sink)
        present(form, in: c)
        focus(try XCTUnwrap(descendants(of: form).compactMap { $0 as? FieldBox }.first).field, in: c)

        XCTAssertTrue(try press(36, flags: [], in: c))

        XCTAssertEqual(sink.submitCount, 1)
    }

    func test_commandReturn_submitsReportIssueFromTheExportButton() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = try makeReportIssue(sink)
        present(form, in: c)
        focus(
            try XCTUnwrap(descendants(of: form).compactMap { $0 as? AppButton }.first { $0.title.hasPrefix("Export") }),
            in: c)

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(sink.submitCount, 1)
    }

    func test_commandReturn_submitsNewWorktreeFromTheBaseSegment() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = try makeNewWorktree(sink)
        present(form, in: c)
        focus(try XCTUnwrap(descendants(of: form).compactMap { $0 as? SegmentedControl }.first), in: c)

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(sink.submitCount, 1)
    }

    func test_commandReturn_submitsToolFloatFromTheGitSegment() throws {
        let c = makeWindow()
        let sink = Sink()
        let form = makeToolFloat(sink)
        present(form, in: c)
        let git = try XCTUnwrap(
            descendants(of: form).compactMap { $0 as? SegmentedControl }.first { $0.optionTitles.first == "Any folder" }
        )
        focus(git, in: c)

        XCTAssertTrue(try press(36, flags: [.command], in: c))

        XCTAssertEqual(sink.submitCount, 1)
    }
}
