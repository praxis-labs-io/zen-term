import AppKit
import XCTest

@testable import ZenTerm

final class UnsavedChangesWindowTests: WindowTestCase {
    private final class Sink {
        var cancelled = 0
        var dismissed = 0
        var submitted = 0
        var backdropCancels = false
    }

    private enum Exit {
        case escape, backdrop
    }

    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    func test_toolFloatForm_asksBeforeDroppingChanges() throws {
        try assertAsksBeforeDroppingChanges(makeToolFloatForm) { try self.type("Open GitDash", intoFieldAt: 0, of: $0) }
    }

    func test_workspaceForm_asksBeforeDroppingChanges() throws {
        try assertAsksBeforeDroppingChanges(makeWorkspaceForm) { try self.type("api", intoFieldAt: 0, of: $0) }
    }

    func test_sshHostForm_asksBeforeDroppingChanges() throws {
        try assertAsksBeforeDroppingChanges(makeSSHHostForm) { try self.type("deploy@box", intoFieldAt: 0, of: $0) }
    }

    func test_reportIssueForm_asksBeforeDroppingChanges() throws {
        try assertAsksBeforeDroppingChanges(makeReportIssueForm) { form in
            let area = try XCTUnwrap(self.descendants(of: form).compactMap { $0 as? TextAreaBox }.first)
            form.window?.makeFirstResponder(area.textView)
            area.textView.insertText("It hung.", replacementRange: area.textView.selectedRange())
        }
    }

    func test_newWorktreeForm_asksBeforeDroppingChanges() throws {
        try assertAsksBeforeDroppingChanges(makeNewWorktreeForm) { try self.type("feature/x", intoFieldAt: 0, of: $0) }
    }

    func test_typingAndErasingBackToTheOpeningText_closesWithoutAsking() throws {
        let (form, sink) = makeSSHHostForm()
        try type("x", intoFieldAt: 0, of: form)
        try XCTUnwrap(form.window?.firstResponder as? NSTextView).deleteBackward(nil)

        _ = form.performKeyEquivalent(with: try escapeKey())

        XCTAssertNil(confirmCard(in: form))
        XCTAssertEqual(sink.cancelled, 1)
    }

    func test_workspaceForm_addingATabIsAChange_butSelectingOneIsNot() throws {
        let editing = Workspace(
            title: "api", path: FileManager.default.temporaryDirectory,
            tabs: [Workspace.Tab(name: "one"), Workspace.Tab(name: "two")], env: [:])
        let (selecting, selectingSink) = makeWorkspaceForm(editing: editing)
        _ = (selecting as? WorkspaceFormOverlay)?.handle(.nextTab)
        _ = selecting.performKeyEquivalent(with: try escapeKey())
        XCTAssertNil(confirmCard(in: selecting))
        XCTAssertEqual(selectingSink.cancelled, 1)

        let (adding, addingSink) = makeWorkspaceForm(editing: editing)
        _ = (adding as? WorkspaceFormOverlay)?.handle(.newTab)
        _ = adding.performKeyEquivalent(with: try escapeKey())
        XCTAssertNotNil(confirmCard(in: adding))
        XCTAssertEqual(addingSink.cancelled, 0)
    }

    func test_commandReturnUnderTheCard_doesNotSubmitTheForm() throws {
        let forms: [(String, () -> (ModalShell, Sink), (ModalShell) throws -> Void)] = [
            ("New Worktree", makeNewWorktreeForm, { try self.type("feature/x", intoFieldAt: 0, of: $0) }),
            (
                "Report an Issue", makeReportIssueForm,
                { form in
                    try self.type("Hang", intoFieldAt: 0, of: form)
                    let area = try XCTUnwrap(self.descendants(of: form).compactMap { $0 as? TextAreaBox }.first)
                    form.window?.makeFirstResponder(area.textView)
                    area.textView.insertText("It hung.", replacementRange: area.textView.selectedRange())
                }
            ),
        ]
        for (name, make, fill) in forms {
            let (form, sink) = make()
            try fill(form)
            _ = form.performKeyEquivalent(with: try escapeKey())
            XCTAssertNotNil(confirmCard(in: form), name)

            _ = form.performKeyEquivalent(with: try commandReturnKey())

            XCTAssertEqual(sink.submitted, 0, name)
        }
    }

    func test_workspaceForm_backdropDuringATabRename_asksAboutTheTypedName() throws {
        let editing = Workspace(
            title: "api", path: FileManager.default.temporaryDirectory, tabs: [Workspace.Tab(name: "one")], env: [:])
        let (form, sink) = makeWorkspaceForm(editing: editing)
        _ = (form as? WorkspaceFormOverlay)?.handle(.renameTab)
        let editor = try XCTUnwrap(form.window?.firstResponder as? NSTextView)
        editor.insertText("logs", replacementRange: editor.selectedRange())

        try clickBackdrop(of: form)

        XCTAssertNotNil(confirmCard(in: form))
        XCTAssertEqual(sink.dismissed, 0)
    }

    func test_keepEditing_afterTheFocusedDrawerClosed_focusesTheForm() throws {
        let (shell, _) = makeWorkspaceForm()
        let form = try XCTUnwrap(shell as? WorkspaceFormOverlay)
        try type("api", intoFieldAt: 0, of: form)
        form.drawingForTesting.rail(.right)?.onOpen?()
        XCTAssertNotNil(form.drawingForTesting.focusedRegion)

        _ = form.performKeyEquivalent(with: try escapeKey())
        XCTAssertNotNil(confirmCard(in: form))
        _ = form.performKeyEquivalent(with: try escapeKey())
        waitUntil(!form.isShowingOverlaidCard, "Esc on the card to return to the form")

        XCTAssertTrue(KeyboardFocus.isFocused(form.titleFieldForTesting.field, in: form.window))
    }

    func test_toolFloatForm_changingASegmentIsAChange() throws {
        let (form, sink) = makeToolFloatForm()
        let segment = try XCTUnwrap(descendants(of: form).compactMap { $0 as? SegmentedControl }.first)
        segment.setSelection(1)

        try clickBackdrop(of: form)

        XCTAssertNotNil(confirmCard(in: form))
        XCTAssertEqual(sink.dismissed, 0)
    }

    private func assertAsksBeforeDroppingChanges(
        _ make: () -> (ModalShell, Sink), change: (ModalShell) throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for exit in [Exit.escape, .backdrop] {
            let (clean, cleanSink) = make()
            try leave(clean, by: exit)
            XCTAssertNil(confirmCard(in: clean), "unchanged, \(exit)", file: file, line: line)
            XCTAssertEqual(exitCount(cleanSink, exit), 1, "unchanged closes, \(exit)", file: file, line: line)

            let (form, sink) = make()
            try change(form)
            let edited = form.window?.firstResponder
            let selection = (edited as? NSTextView)?.selectedRange()
            try leave(form, by: exit)
            let card = try XCTUnwrap(confirmCard(in: form), "changed asks, \(exit)", file: file, line: line)
            XCTAssertEqual(sink.cancelled + sink.dismissed, 0, "the form stays open, \(exit)", file: file, line: line)
            XCTAssertIdentical(
                form.window?.firstResponder, card, "no button starts focused: discarding cannot be undone",
                file: file, line: line)

            try leave(form, by: .escape)
            waitUntil(!form.isShowingOverlaidCard, "Esc on the card to return to the form", file: file, line: line)
            XCTAssertEqual(sink.cancelled + sink.dismissed, 0, "Esc on the card keeps editing", file: file, line: line)
            XCTAssertIdentical(form.window?.firstResponder, edited, "focus returns", file: file, line: line)
            XCTAssertEqual(
                (form.window?.firstResponder as? NSTextView)?.selectedRange(), selection, "the caret stays put",
                file: file, line: line)

            try leave(form, by: exit)
            let again = try XCTUnwrap(confirmCard(in: form), file: file, line: line)
            try XCTUnwrap(button("Discard changes", in: again), file: file, line: line).onTap()
            XCTAssertEqual(exitCount(sink, exit), 1, "Discard completes the \(exit) exit", file: file, line: line)

            let (cancelling, cancelSink) = make()
            try change(cancelling)
            try XCTUnwrap(button("Cancel", in: cancelling), file: file, line: line).onTap()
            XCTAssertNil(confirmCard(in: cancelling), "Cancel never asks", file: file, line: line)
            XCTAssertEqual(cancelSink.cancelled, 1, file: file, line: line)
        }
    }

    private func exitCount(_ sink: Sink, _ exit: Exit) -> Int {
        exit == .escape || sink.backdropCancels ? sink.cancelled : sink.dismissed
    }

    private func leave(_ form: ModalShell, by exit: Exit) throws {
        switch exit {
        case .escape: _ = form.performKeyEquivalent(with: try escapeKey())
        case .backdrop: try clickBackdrop(of: form)
        }
    }

    private func makeToolFloatForm() -> (ModalShell, Sink) {
        let sink = Sink()
        let form = ToolFloatFormOverlay(
            editing: nil, existingIDs: [], capturer: nil, onSubmit: { _ in nil },
            onCancel: { sink.cancelled += 1 }, onDismiss: { sink.dismissed += 1 })
        return (mount(form), sink)
    }

    private func makeWorkspaceForm() -> (ModalShell, Sink) { makeWorkspaceForm(editing: nil) }

    private func makeWorkspaceForm(editing: Workspace?) -> (ModalShell, Sink) {
        let sink = Sink()
        let form = WorkspaceFormOverlay(
            editing: editing, existingTitles: [], onSubmit: { _ in nil },
            onCancel: { sink.cancelled += 1 }, onDismiss: { sink.dismissed += 1 })
        return (mount(form), sink)
    }

    private func makeSSHHostForm() -> (ModalShell, Sink) {
        let sink = Sink()
        let form = AddSSHHostOverlay(
            mode: .add(taken: []), onSubmit: { _ in nil },
            onCancel: { sink.cancelled += 1 }, onDismiss: { sink.dismissed += 1 })
        return (mount(form), sink)
    }

    private func makeReportIssueForm() -> (ModalShell, Sink) {
        let sink = Sink()
        sink.backdropCancels = true
        let form = ReportIssueOverlay(
            report: SystemReport(appVersion: "0.3.0", build: "1", osVersion: "15.5", architecture: "arm64"),
            onOpenURL: { _ in
                sink.submitted += 1
                return nil
            }, onExportDiagnostics: {}, onCancel: { sink.cancelled += 1 })
        return (mount(form), sink)
    }

    private func makeNewWorktreeForm() -> (ModalShell, Sink) {
        let sink = Sink()
        let form = NewWorktreeOverlay(
            workspace: Workspace(
                title: "ZenTerm", path: URL(fileURLWithPath: "/tmp/zenterm-fixture"), tabs: [], env: [:]),
            options: WorktreeStore.CreateOptions(
                branches: [], defaultBase: "origin/main", currentBranch: "main", holders: [:]),
            onSubmit: { _ in sink.submitted += 1 }, onCancel: { sink.cancelled += 1 },
            onDismiss: { sink.dismissed += 1 })
        return (mount(form), sink)
    }

    private func mount(_ form: ModalShell) -> ModalShell {
        form.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(form)
        form.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return form
    }

    private func type(_ text: String, intoFieldAt index: Int, of form: ModalShell) throws {
        let fields = descendants(of: form).compactMap { $0 as? FieldBox }
        let box = try XCTUnwrap(fields.indices.contains(index) ? fields[index] : nil)
        form.window?.makeFirstResponder(box.field)
        let editor = try XCTUnwrap(form.window?.firstResponder as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func confirmCard(in form: ModalShell) -> ConfirmCard? {
        form.isShowingOverlaidCard ? form.confirm.card : nil
    }

    private func button(_ title: String, in view: NSView) -> AppButton? {
        descendants(of: view).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func clickBackdrop(of form: ModalShell) throws {
        try XCTUnwrap(form.subviews.compactMap { $0 as? BackdropView }.first).mouseDown(with: NSEvent())
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func commandReturnKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private func escapeKey() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
    }
}
