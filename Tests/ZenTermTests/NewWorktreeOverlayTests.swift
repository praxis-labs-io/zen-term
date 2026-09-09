import AppKit
import XCTest

@testable import ZenTerm

/// The create-a-worktree card, driven through its real controls in a window. A state-only test
/// would pass while a control was dead.
final class NewWorktreeOverlayTests: WindowTestCase {
    private final class Sink {
        var submitted: [(branch: String, base: WorktreeStore.Base)] = []
        var cancelled = 0
        var dismissed = 0
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

    // MARK: validation

    func test_submittingAnEmptyBranch_flagsTheFieldAndDoesNotSubmit() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "Enter a branch name.")
    }

    func test_aBranchThatAlreadyExists_isRefusedBeforeSubmit() throws {
        let (overlay, sink) = mount(branches: ["feature/zen-473"])

        branchField(in: overlay).setText("feature/zen-473")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "That branch already exists.")
    }

    /// `check-ref-format` passes `-m`, and `worktree add -b -m` then renames the repo's own branch.
    func test_aLeadingDash_neverReachesGit() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("-m")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "Can't start with a dash.")
    }

    func test_aBranchWithASpace_isRefused() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("my branch")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "Can't contain spaces.")
    }

    /// Git keeps a ref in a file, so a branch cannot be both a name and a folder of names. Both
    /// directions are knowable from the same set the exact-match check already reads.
    func test_aNameAlreadyUsedAsAFolder_isRefused() throws {
        let (overlay, sink) = mount(branches: ["test/branch-test", "test/test-1"])

        branchField(in: overlay).setText("test")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(
            inlineMessage(in: overlay), "test/branch-test already uses this name as a folder.",
            "names the offender, and the same one every run")
    }

    func test_aNameUnderAnExistingBranch_isRefused() throws {
        let (overlay, sink) = mount(branches: ["test"])

        branchField(in: overlay).setText("test/spike")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(
            inlineMessage(in: overlay), "test is already a branch, so this can't be a folder.")
    }

    /// The conflict can sit any number of segments up, not just at the first one.
    func test_aDeepNameUnderAnExistingBranch_namesTheBranchInTheWay() throws {
        let (overlay, _) = mount(branches: ["feature/zen"])

        branchField(in: overlay).setText("feature/zen/473")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(
            inlineMessage(in: overlay), "feature/zen is already a branch, so this can't be a folder.")
    }

    /// A shared prefix that is not a whole path segment is not a conflict.
    func test_aNameSharingAPrefixButNotASegment_isFine() throws {
        let (overlay, sink) = mount(branches: ["test/branch-test"])

        branchField(in: overlay).setText("testing")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first?.branch, "testing")
    }

    // MARK: submit

    func test_submit_handsBackTheTrimmedBranchAndTheDefaultBase() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("  feature/zen-473  ")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first?.branch, "feature/zen-473")
        XCTAssertEqual(sink.submitted.first?.base, .defaultBranch)
    }

    func test_theSecondBaseSegment_cutsFromTheCurrentCheckout() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(segment(in: overlay)).select(1)
        branchField(in: overlay).setText("spike")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first?.base, .currentCheckout)
    }

    // MARK: the create's own state

    func test_whileWorking_bothButtonsAreOffAndEscapeDoesNothing() throws {
        let (overlay, sink) = mount()

        overlay.beginWork("Creating spike")

        XCTAssertFalse(try XCTUnwrap(button(in: overlay, title: "Create Worktree")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(button(in: overlay, title: "Cancel")).isEnabled)
        pressEscape()
        XCTAssertEqual(sink.cancelled, 0)
    }

    func test_whileWorking_aSecondSubmitDoesNotRunTheCreateTwice() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("spike")
        let create = try XCTUnwrap(button(in: overlay, title: "Create Worktree"))
        create.onTap()
        overlay.beginWork("Creating spike")
        create.onTap()

        XCTAssertEqual(sink.submitted.count, 1)
    }

    func test_failing_handsTheCardBackWithTheReason() throws {
        let (overlay, sink) = mount()
        overlay.beginWork("Creating spike")

        overlay.failWork("A branch named spike already exists.")

        XCTAssertTrue(try XCTUnwrap(button(in: overlay, title: "Create Worktree")).isEnabled)
        XCTAssertEqual(
            visibleText(in: overlay).first { $0.hasPrefix("A branch named") },
            "A branch named spike already exists.")
        pressEscape()
        XCTAssertEqual(sink.cancelled, 1)
    }

    // MARK: the base captions name the ref

    func test_theBaseCaption_namesTheRefEachChoiceCutsFrom() throws {
        let (overlay, _) = mount(defaultBase: "origin/main", currentBranch: "feature/zen-455")

        XCTAssertTrue(visibleText(in: overlay).contains("Starts from origin/main."))
        try XCTUnwrap(segment(in: overlay)).select(1)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from feature/zen-455."))
    }

    /// A detached checkout and a repo with no remote leave nothing to name.
    func test_withNothingToName_theCaptionStillSaysWhichChoiceItIs() throws {
        let (overlay, _) = mount(defaultBase: nil, currentBranch: nil)

        XCTAssertTrue(visibleText(in: overlay).contains("Starts from the default branch."))
        try XCTUnwrap(segment(in: overlay)).select(1)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from this checkout."))
    }

    // MARK: the phase line

    func test_thePhaseLine_isHiddenAtRestAndNamesTheStepWhileWorking() {
        let (overlay, _) = mount()

        XCTAssertFalse(visibleText(in: overlay).contains("Creating spike"))
        overlay.beginWork("Creating spike")
        XCTAssertTrue(visibleText(in: overlay).contains("Creating spike"))

        overlay.setPhase("Carrying node_modules")
        XCTAssertTrue(visibleText(in: overlay).contains("Carrying node_modules"))
        XCTAssertFalse(visibleText(in: overlay).contains("Creating spike"))
    }

    func test_failing_takesThePhaseLineBackDown() {
        let (overlay, _) = mount()
        overlay.beginWork("Creating spike")

        overlay.failWork("That branch already exists.")

        XCTAssertFalse(visibleText(in: overlay).contains("Creating spike"))
    }

    /// Clicking out is a way out, not a way back. Esc and Cancel return to the list; this does not.
    func test_theBackdrop_dismissesRatherThanReturningToThePicker() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(backdrop(in: overlay)).mouseDown(with: NSEvent())

        XCTAssertEqual(sink.dismissed, 1)
        XCTAssertEqual(sink.cancelled, 0)
    }

    func test_theCancelButton_returnsToThePickerRatherThanDismissing() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(button(in: overlay, title: "Cancel")).onTap()

        XCTAssertEqual(sink.cancelled, 1)
        XCTAssertEqual(sink.dismissed, 0)
    }

    func test_whileWorking_theBackdropIsDeadToo() throws {
        let (overlay, sink) = mount()
        overlay.beginWork("Creating spike")

        try XCTUnwrap(backdrop(in: overlay)).mouseDown(with: NSEvent())

        XCTAssertEqual(sink.dismissed, 0)
    }

    /// The base the caption describes has to stay the base that was submitted.
    func test_whileWorking_theBaseSegmentIsLocked() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))

        overlay.beginWork("Creating spike")

        // The flag is not the lock: `NSButton` is what refuses the click, so assert on the segments.
        XCTAssertEqual(segmentButtons(in: base).filter(\.isEnabled), [])
        XCTAssertFalse(base.acceptsFirstResponder)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from origin/main."))

        overlay.failWork("nope")

        XCTAssertEqual(segmentButtons(in: base).filter { !$0.isEnabled }, [], "and it comes back")
        XCTAssertTrue(base.acceptsFirstResponder)
    }

    /// The message named a branch the user has since retyped.
    func test_typingAfterAFailure_clearsTheError() throws {
        let (overlay, _) = mount()
        overlay.beginWork("Creating spike")
        overlay.failWork("That branch already exists.")

        branchField(in: overlay).setText("spike-2")
        branchField(in: overlay).onChange?()

        XCTAssertFalse(visibleText(in: overlay).contains("That branch already exists."))
    }

    // MARK: carry

    func test_theCarryLine_namesWhatTheWorkspaceCarries() throws {
        let (overlay, _) = mount(carry: ["node_modules", ".env"])

        XCTAssertTrue(visibleText(in: overlay).contains("node_modules, .env"))
    }

    func test_withNoCarryConfigured_theLineSaysWhereToSetIt() throws {
        let (overlay, _) = mount(carry: [])

        XCTAssertTrue(
            visibleText(in: overlay).contains(
                "Nothing set. Pick what to carry when you edit this workspace."))
    }

    // MARK: keyboard

    func test_downAndUp_walkTheBaseSegmentBetweenTheBranchFieldAndCreate() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))
        let create = try XCTUnwrap(button(in: overlay, title: "Create Worktree"))
        window?.makeFirstResponder(base)

        base.keyDown(with: try arrow(down: true))
        XCTAssertTrue(KeyboardFocus.isFocused(create, in: window))

        create.keyDown(with: try arrow(down: false))
        XCTAssertTrue(KeyboardFocus.isFocused(base, in: window))
    }

    /// Cancel is not in `verticalStops`, so Up from it has to resolve through Create.
    func test_upFromCancel_reachesTheBaseSegment() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))
        let cancel = try XCTUnwrap(button(in: overlay, title: "Cancel"))
        window?.makeFirstResponder(cancel)

        cancel.keyDown(with: try arrow(down: false))

        XCTAssertTrue(KeyboardFocus.isFocused(base, in: window))
    }

    // MARK: harness

    private func mount(
        carry: [String] = [], branches: Set<String> = [], defaultBase: String? = "origin/main",
        currentBranch: String? = "feature/zen-455"
    ) -> (overlay: NewWorktreeOverlay, sink: Sink) {
        let sink = Sink()
        let workspace = Workspace(
            title: "ZenTerm", path: URL(fileURLWithPath: "/tmp/zenterm-fixture"),
            main: nil, right: nil, bottom: nil, focus: .main, env: [:], carry: carry)
        let overlay = NewWorktreeOverlay(
            workspace: workspace,
            options: WorktreeStore.CreateOptions(
                branches: branches, defaultBase: defaultBase, currentBranch: currentBranch),
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { sink.submitted.append((branch: $0, base: $1)) },
            onCancel: { sink.cancelled += 1 },
            onDismiss: { sink.dismissed += 1 })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return (overlay, sink)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func branchField(in overlay: NSView) -> FieldBox {
        descendants(of: overlay).compactMap { $0 as? FieldBox }.first!
    }

    private func button(in overlay: NSView, title: String) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func segmentButtons(in segment: SegmentedControl) -> [AppButton] {
        descendants(of: segment).compactMap { $0 as? AppButton }
    }

    private func backdrop(in overlay: NSView) -> BackdropView? {
        descendants(of: overlay).compactMap { $0 as? BackdropView }.first
    }

    private func segment(in overlay: NSView) -> SegmentedControl? {
        descendants(of: overlay).compactMap { $0 as? SegmentedControl }.first
    }

    /// Every label on screen. An editable field holds the typed value, not copy.
    private func visibleText(in overlay: NSView) -> [String] {
        descendants(of: overlay)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
    }

    /// The inline validation message. The caption is a `FieldCaption` and the field is editable,
    /// so neither is mistaken for it.
    private func inlineMessage(in overlay: NSView) -> String? {
        guard let group = descendants(of: overlay).compactMap({ $0 as? LabeledField }).first
        else { return nil }
        return descendants(of: group)
            .compactMap { $0 as? NSTextField }
            .first { !($0 is FieldCaption) && !$0.isEditable && !$0.isHidden }?
            .stringValue
    }

    /// AppKit hangs `.function` and `.numericPad` on every arrow; without them this is a
    /// keystroke macOS never sends.
    private func arrow(down: Bool) throws -> NSEvent {
        let character = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false,
                keyCode: down ? 125 : 126))
    }

    /// `NSWindow.sendEvent`'s path: a traversal from the content view, where the card claims it.
    @discardableResult
    private func pressEscape() -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window!.contentView!.performKeyEquivalent(with: esc)
    }
}
